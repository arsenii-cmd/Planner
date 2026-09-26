#!/usr/bin/env python3
"""plannerd — LAN sync server for events, day tasks and quick notes.

Storage: SQLite (~/.local/share/planner/planner.db)
API (JSON; HTTPS with a self-signed cert pinned via the pairing QR on the LAN port,
plain HTTP on 127.0.0.1:<local_port> for the Serpantinum panel):
  GET  /api/ping                      -> {"name", "version"}
  GET  /api/items?from=YYYY-MM-DD&to=YYYY-MM-DD&kind=event,task
  GET  /api/notes
  POST /api/items          {item}     -> create or update (id optional)
    optional "repeat": {"unit": "week"|"month", "count": N} creates a series
  POST /api/items/<id>/delete
  POST /api/series/<series>/delete
  POST /api/quick          {"text", "date"?} -> parse Russian free text ("завтра 18:00 занятие"), create it
  POST /api/sync           {"since": seq, "changes": [item...]}
                           -> {"seq": seq, "changes": [item...]}
Requests from loopback need no token; everything else needs
"Authorization: Bearer <token>".
Events with "remind" (minutes before start_time) also pop a desktop notification.

Server mode (`plannerd serve --server 127.0.0.1:47212`) is for a machine behind a TLS
reverse proxy: plain HTTP on that one address only, the token is required from every
client (loopback included, since the proxy connects from there), no mDNS, no desktop
notifications. Phones pair with `plannerd pair --url https://planner.example.com`.

Conflict rule: last writer wins by updated_at (ms), ties broken by device id.
Deletes are tombstones (deleted = 1) so they sync too.
"""

import argparse
import hashlib
import json
import os
import secrets
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # quickparse.py next to the real file
import quickparse  # noqa: E402

VERSION = 2
DEFAULT_PORT = 47210
DEFAULT_LOCAL_PORT = 47211
DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "planner"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "planner"
KINDS = ("event", "task", "note")
FIELDS = ("id", "kind", "title", "body", "date", "start_time", "end_time",
          "done", "color", "remind", "series", "updated_at", "deleted", "device")

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    title       TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT '',
    date        TEXT,
    start_time  TEXT,
    end_time    TEXT,
    done        INTEGER NOT NULL DEFAULT 0,
    color       TEXT,
    remind      INTEGER,
    series      TEXT,
    updated_at  INTEGER NOT NULL,
    deleted     INTEGER NOT NULL DEFAULT 0,
    device      TEXT NOT NULL DEFAULT '',
    seq         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS items_date ON items(date);
CREATE INDEX IF NOT EXISTS items_seq ON items(seq);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


MAX_REPEAT = {"week": 52, "month": 24}


def shift_date(date_str, unit, steps):
    """date + steps weeks/months; months clamp to the last day (31 Jan + 1 month = 28/29 Feb)."""
    import calendar
    from datetime import date, timedelta
    d = date.fromisoformat(date_str)
    if unit == "week":
        return (d + timedelta(weeks=steps)).isoformat()
    month0 = d.month - 1 + steps
    year, month = d.year + month0 // 12, month0 % 12 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1])).isoformat()


def now_ms():
    return int(time.time() * 1000)


def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path = CONFIG_DIR / "config.json"
    cfg = {}
    if path.exists():
        cfg = json.loads(path.read_text())
    changed = False
    if "token" not in cfg:
        cfg["token"] = secrets.token_urlsafe(24)
        changed = True
    if "port" not in cfg:
        cfg["port"] = DEFAULT_PORT
        changed = True
    if "local_port" not in cfg:
        cfg["local_port"] = DEFAULT_LOCAL_PORT
        changed = True
    if "name" not in cfg:
        cfg["name"] = socket.gethostname()
        changed = True
    if changed:
        path.write_text(json.dumps(cfg, indent=2))
        path.chmod(0o600)
    return cfg


class Store:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(items)")}
        for col, decl in (("remind", "INTEGER"), ("series", "TEXT")):  # older databases
            if col not in cols:
                self.db.execute("ALTER TABLE items ADD COLUMN %s %s" % (col, decl))
        self.db.commit()
        self.lock = threading.Lock()

    def _next_seq(self):
        row = self.db.execute("SELECT COALESCE(MAX(seq), 0) FROM items").fetchone()
        return row[0] + 1

    def current_seq(self):
        with self.lock:
            return self._next_seq() - 1

    @staticmethod
    def _row(row):
        d = {k: row[k] for k in FIELDS}
        d["done"] = bool(d["done"])
        d["deleted"] = bool(d["deleted"])
        return d

    @staticmethod
    def normalize(raw, device):
        if not isinstance(raw, dict):
            raise ValueError("item must be an object")
        kind = raw.get("kind")
        if kind not in KINDS:
            raise ValueError("kind must be one of %s" % ", ".join(KINDS))
        item = {
            "id": str(raw.get("id") or uuid.uuid4()),
            "kind": kind,
            "title": str(raw.get("title") or "")[:500],
            "body": str(raw.get("body") or "")[:20000],
            "date": raw.get("date") or None,
            "start_time": raw.get("start_time") or None,
            "end_time": raw.get("end_time") or None,
            "done": 1 if raw.get("done") else 0,
            "color": raw.get("color") or None,
            "remind": Store._remind(raw.get("remind")),
            "series": str(raw["series"]) if raw.get("series") else None,
            "updated_at": int(raw.get("updated_at") or now_ms()),
            "deleted": 1 if raw.get("deleted") else 0,
            "device": str(raw.get("device") or device),
        }
        if kind in ("event", "task") and not item["date"] and not item["deleted"]:
            raise ValueError("%s needs a date" % kind)
        return item

    @staticmethod
    def _remind(value):
        if value is None or value == "":
            return None
        return max(0, min(int(value), 7 * 24 * 60))

    def upsert(self, item):
        """Apply one change if it is newer. Returns True when stored."""
        with self.lock:
            cur = self.db.execute(
                "SELECT updated_at, device FROM items WHERE id = ?", (item["id"],)
            ).fetchone()
            if cur and (cur["updated_at"], cur["device"]) >= (item["updated_at"], item["device"]):
                return False
            item = dict(item, seq=self._next_seq())
            cols = ", ".join(item)
            marks = ", ".join("?" for _ in item)
            self.db.execute(
                "INSERT OR REPLACE INTO items (%s) VALUES (%s)" % (cols, marks),
                tuple(item.values()),
            )
            self.db.commit()
            return True

    def get(self, item_id):
        with self.lock:
            row = self.db.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
        return self._row(row) if row else None

    def range(self, date_from, date_to, kinds):
        q = "SELECT * FROM items WHERE deleted = 0 AND date >= ? AND date <= ?"
        args = [date_from, date_to]
        if kinds:
            q += " AND kind IN (%s)" % ", ".join("?" for _ in kinds)
            args += kinds
        q += " ORDER BY date, COALESCE(start_time, '99:99'), updated_at"
        with self.lock:
            return [self._row(r) for r in self.db.execute(q, args)]

    def notes(self):
        with self.lock:
            rows = self.db.execute(
                "SELECT * FROM items WHERE deleted = 0 AND kind = 'note' ORDER BY updated_at DESC"
            )
            return [self._row(r) for r in rows]

    def create(self, item, repeat=None):
        """Store a new item; repeat={"unit","count"} makes a series of count occurrences."""
        if repeat and item["date"]:
            unit = repeat.get("unit")
            if unit not in MAX_REPEAT:
                raise ValueError("repeat.unit must be week or month")
            count = max(1, min(int(repeat.get("count") or 1), MAX_REPEAT[unit]))
            if count > 1:
                series = str(uuid.uuid4())
                for i in range(count):
                    occ = dict(item, series=series, date=shift_date(item["date"], unit, i))
                    if i:
                        occ["id"] = str(uuid.uuid4())
                    self.upsert(occ)
                return self.get(item["id"])
        self.upsert(item)
        return self.get(item["id"])

    def carry_over_tasks(self, today):
        """Unfinished one-off tasks from past days move to today. Returns how many moved."""
        with self.lock:
            rows = self.db.execute(
                "SELECT * FROM items WHERE kind = 'task' AND deleted = 0 AND done = 0 "
                "AND series IS NULL AND date < ?", (today,)).fetchall()
        stamp = now_ms()
        for r in rows:
            it = self._row(r)
            it.update(date=today, updated_at=stamp, device="laptop")
            self.upsert(Store.normalize(it, "laptop"))
        return len(rows)

    def series_items(self, series):
        with self.lock:
            rows = self.db.execute("SELECT * FROM items WHERE series = ? AND deleted = 0", (series,))
            return [self._row(r) for r in rows]

    def get_meta(self, key, default=None):
        with self.lock:
            row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else default

    def set_meta(self, key, value):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))
            self.db.commit()

    def since(self, seq):
        with self.lock:
            rows = self.db.execute("SELECT * FROM items WHERE seq > ? ORDER BY seq", (seq,))
            return [self._row(r) for r in rows]


class Handler(BaseHTTPRequestHandler):
    server_version = "plannerd/%d" % VERSION
    store = None
    config = None
    trust_loopback = True  # off in server mode: the reverse proxy connects from loopback

    def log_message(self, fmt, *args):
        if os.environ.get("PLANNER_DEBUG"):
            super().log_message(fmt, *args)

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.trust_loopback and self.client_address[0] in ("127.0.0.1", "::1"):
            return True
        auth = self.headers.get("Authorization", "")
        return secrets.compare_digest(auth, "Bearer " + self.config["token"])

    def _json_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 5_000_000:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def _dispatch(self, method):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if parts == ["api", "ping"]:
            return self._send(200, {"name": self.config["name"], "version": VERSION})
        if not self._authorized():
            return self._send(401, {"error": "unauthorized"})
        try:
            if method == "GET" and parts == ["api", "items"]:
                qs = parse_qs(url.query)
                date_from = qs.get("from", ["0000-01-01"])[0]
                date_to = qs.get("to", ["9999-12-31"])[0]
                kinds = [k for k in qs.get("kind", [""])[0].split(",") if k]
                return self._send(200, self.store.range(date_from, date_to, kinds))
            if method == "GET" and parts == ["api", "notes"]:
                return self._send(200, self.store.notes())
            if method == "POST" and parts == ["api", "items"]:
                raw = self._json_body()
                raw["updated_at"] = now_ms()
                repeat = raw.pop("repeat", None)
                item = Store.normalize(raw, "laptop")
                if self.store.get(item["id"]):
                    repeat = None  # editing an existing item never fans out
                return self._send(200, self.store.create(item, repeat))
            if method == "POST" and parts == ["api", "quick"]:
                body = self._json_body()
                return self._send(200, quick_add(self.store, str(body.get("text") or ""), body.get("date")))
            if method == "POST" and len(parts) == 4 and parts[:2] == ["api", "series"] and parts[3] == "delete":
                stamp = now_ms()
                items = self.store.series_items(parts[2])
                for cur in items:
                    cur.update(deleted=True, updated_at=stamp, device="laptop")
                    self.store.upsert(Store.normalize(cur, "laptop"))
                return self._send(200, {"deleted": len(items)})
            if method == "POST" and len(parts) == 4 and parts[:2] == ["api", "items"] and parts[3] == "delete":
                cur = self.store.get(parts[2])
                if not cur:
                    return self._send(404, {"error": "not found"})
                cur.update(deleted=True, updated_at=now_ms(), device="laptop")
                self.store.upsert(Store.normalize(cur, "laptop"))
                return self._send(200, {"ok": True})
            if method == "POST" and parts == ["api", "sync"]:
                body = self._json_body()
                since = int(body.get("since") or 0)
                for raw in body.get("changes") or []:
                    self.store.upsert(Store.normalize(raw, "phone"))
                return self._send(200, {
                    "seq": self.store.current_seq(),
                    "changes": self.store.since(since),
                })
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            return self._send(400, {"error": str(exc)})
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


def quick_add(store, text, default_date=None):
    parsed = quickparse.parse(text, default_date)
    if not parsed["title"]:
        raise ValueError("пустое название")
    repeat = parsed.pop("repeat", None)
    parsed["updated_at"] = now_ms()
    item = store.create(Store.normalize(parsed, "laptop"), repeat)
    return {"item": item, "summary": quickparse.describe(dict(parsed, repeat=repeat))}


def notify(title, body="", urgency="normal"):
    subprocess.run(["notify-send", "-a", "Planner", "-i", "x-office-calendar", "-u", urgency, title, body], check=False)


def ensure_cert():
    """Self-signed certificate for the LAN port; phones pin its SHA-256 fingerprint."""
    cert, key = CONFIG_DIR / "cert.pem", CONFIG_DIR / "key.pem"
    if not (cert.exists() and key.exists()):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-nodes", "-days", "3650", "-subj", "/CN=plannerd",
            "-keyout", str(key), "-out", str(cert),
        ], check=True, capture_output=True)
        key.chmod(0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    return cert, key, hashlib.sha256(der).hexdigest()


class Reminder(threading.Thread):
    """Desktop notifications for events with a reminder, checked every 30 s."""

    def __init__(self, store, notify=True):
        super().__init__(daemon=True)
        self.store = store
        self.notify = notify  # False on a headless server: only the daily task carry-over runs
        self.sent = set(json.loads(store.get_meta("reminded", "[]")))

    SUMMARY_HOUR = 8

    def daily(self, now):
        """Once per day: move unfinished tasks to today, then the morning summary (until noon)."""
        today = now.strftime("%Y-%m-%d")
        if self.store.get_meta("carried") != today:
            moved = self.store.carry_over_tasks(today)
            self.store.set_meta("carried", today)
            if moved:
                print("carried %d task(s) to %s" % (moved, today), flush=True)
        if not self.notify:
            return
        if self.store.get_meta("summary") == today or not (self.SUMMARY_HOUR <= now.hour < 12):
            return
        self.store.set_meta("summary", today)
        items = self.store.range(today, today, ["event", "task"])
        events = [i for i in items if i["kind"] == "event"]
        tasks = [i for i in items if i["kind"] == "task" and not i["done"]]
        if not events and not tasks:
            return
        lines = ["%s %s" % (e["start_time"] or "весь день", e["title"] or e["body"].split("\n")[0]) for e in events]
        lines += ["☐ %s" % (t["title"] or t["body"].split("\n")[0]) for t in tasks]
        head = []
        if events:
            head.append("%d %s" % (len(events), "событие" if len(events) == 1 else ("события" if len(events) < 5 else "событий")))
        if tasks:
            head.append("%d %s" % (len(tasks), "задача" if len(tasks) == 1 else ("задачи" if len(tasks) < 5 else "задач")))
        notify("Сегодня: " + ", ".join(head), "\n".join(lines[:8]))

    def run(self):
        from datetime import datetime, timedelta
        while True:
            try:
                now = datetime.now()
                self.daily(now)
                if not self.notify:
                    time.sleep(30)
                    continue
                days = [(now + timedelta(days=d)).strftime("%Y-%m-%d") for d in (-1, 0, 1, 8)]
                for it in self.store.range(days[0], days[3], ["event"]):
                    if it["remind"] is None or not it["start_time"]:
                        continue
                    start = datetime.strptime(it["date"] + " " + it["start_time"], "%Y-%m-%d %H:%M")
                    fire = start - timedelta(minutes=it["remind"])
                    mark = "%s@%s %s" % (it["id"], it["date"], it["start_time"])
                    if mark in self.sent or not (fire <= now < start + timedelta(minutes=10)):
                        continue
                    body = "%s%s" % (it["start_time"], (" — " + it["body"]) if it["body"] else "")
                    notify(it["title"] or it["body"].split("\n")[0] or "Событие", body)
                    self.sent.add(mark)
                    self.store.set_meta("reminded", json.dumps(sorted(self.sent)[-500:]))
            except Exception as exc:
                print("reminder error: %s" % exc, file=sys.stderr, flush=True)
            time.sleep(30)


def lan_addresses():
    """Private IPv4 addresses of real LAN interfaces (skips VPN tunnels and docker)."""
    import ipaddress
    import subprocess
    try:
        out = subprocess.run(["ip", "-j", "-4", "addr"], capture_output=True, text=True, check=True).stdout
        links = json.loads(out)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []
    skip = ("lo", "tun", "tap", "wg", "docker", "br-", "veth", "virbr", "hiddify", "singbox")
    addrs = []
    for link in links:
        name = link.get("ifname", "")
        if name.startswith(skip) or "UP" not in link.get("flags", []):
            continue
        for a in link.get("addr_info", []):
            ip = ipaddress.ip_address(a["local"])
            if ip.is_private and not ip.is_loopback and not ip.is_link_local:
                addrs.append(str(ip))
    return sorted(set(addrs))


class Advertiser(threading.Thread):
    """Publishes _planner._tcp over mDNS and re-publishes when the LAN address changes."""

    def __init__(self, cfg):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.zc = None
        self.info = None
        self.addrs = None
        self.stop_event = threading.Event()

    def _publish(self, addrs):
        from zeroconf import ServiceInfo, Zeroconf
        self._unpublish()
        if not addrs:
            return
        self.info = ServiceInfo(
            "_planner._tcp.local.",
            "%s._planner._tcp.local." % self.cfg["name"],
            addresses=[socket.inet_aton(a) for a in addrs],
            port=self.cfg["port"],
            properties={"version": str(VERSION)},
            server="%s.local." % self.cfg["name"],
        )
        self.zc = Zeroconf(interfaces=addrs)
        self.zc.register_service(self.info)

    def _unpublish(self):
        if self.zc:
            try:
                self.zc.unregister_service(self.info)
                self.zc.close()
            except Exception:
                pass
        self.zc = self.info = None

    def run(self):
        try:
            import zeroconf  # noqa: F401
        except ImportError:
            print("zeroconf not installed; mDNS discovery disabled", file=sys.stderr)
            return
        while not self.stop_event.is_set():
            addrs = lan_addresses()
            if addrs != self.addrs:
                try:
                    self._publish(addrs)
                    self.addrs = addrs
                    print("mDNS: %s" % (", ".join(addrs) or "no LAN"), flush=True)
                except Exception as exc:
                    print("mDNS error: %s" % exc, file=sys.stderr, flush=True)
            self.stop_event.wait(15)
        self._unpublish()


def cmd_serve(args):
    cfg = load_config()
    Handler.config = cfg
    Handler.store = Store(DATA_DIR / "planner.db")
    if args.server:
        return serve_behind_proxy(args.server)
    cert, key, fingerprint = ensure_cert()
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    Handler.timeout = 20
    httpd = ThreadingHTTPServer(("0.0.0.0", cfg["port"]), Handler)
    # Handshake happens lazily in the handler thread, so a stalled client can't block accept().
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
    def handle_error(request, client_address):
        # Plain-HTTP or wrong-certificate clients just fail the handshake; no traceback spam.
        exc = sys.exc_info()[1]
        if isinstance(exc, (ssl.SSLError, ConnectionError, TimeoutError)):
            return
        ThreadingHTTPServer.handle_error(httpd, request, client_address)
    httpd.handle_error = handle_error
    local = ThreadingHTTPServer(("127.0.0.1", cfg["local_port"]), Handler)
    threading.Thread(target=local.serve_forever, daemon=True).start()
    Reminder(Handler.store).start()
    mdns = Advertiser(cfg)
    mdns.start()
    print("plannerd: https :%d (LAN), http 127.0.0.1:%d (panel), cert %s…"
          % (cfg["port"], cfg["local_port"], fingerprint[:16]), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        mdns.stop_event.set()
        mdns.join(timeout=3)


def serve_behind_proxy(addr):
    host, _, port = addr.rpartition(":")
    if not host or not port.isdigit():
        print("--server expects HOST:PORT, e.g. 127.0.0.1:47212", file=sys.stderr)
        return 2
    Handler.trust_loopback = False
    Handler.timeout = 20
    httpd = ThreadingHTTPServer((host.strip("[]"), int(port)), Handler)
    Reminder(Handler.store, notify=False).start()
    print("plannerd: server mode, http %s:%s (token required, behind a TLS proxy)" % (host, port), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_pair(args):
    import shutil
    import subprocess
    cfg = load_config()
    if args.url:
        # Server mode: the phone reaches a public HTTPS address with a CA-signed certificate,
        # so there is nothing to pin and no LAN hosts to try.
        payload = json.dumps({"planner": VERSION, "name": cfg["name"], "url": args.url.rstrip("/"),
                              "token": cfg["token"]}, separators=(",", ":"))
        if shutil.which("qrencode"):
            subprocess.run(["qrencode", "-t", "ansiutf8", "-m", "2", payload])
        print("\nОтсканируй QR в приложении Planner на телефоне.")
        print("Вручную: адрес %s, ключ %s" % (args.url.rstrip("/"), cfg["token"]))
        return 0
    addrs = lan_addresses()
    _, _, fingerprint = ensure_cert()
    payload = json.dumps({
        "planner": VERSION,
        "fp": fingerprint,
        "name": cfg["name"],
        "hosts": addrs,
        "port": cfg["port"],
        "token": cfg["token"],
    }, separators=(",", ":"))
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ansiutf8", "-m", "2", payload])
    print("\nОтсканируй QR в приложении Planner на телефоне.")
    print("Вручную: адрес %s, порт %d, ключ %s" % (", ".join(addrs) or "?", cfg["port"], cfg["token"]))


def cmd_add(args):
    """Quick add from the command line / Win+P window, via the running service when possible."""
    import urllib.error
    import urllib.request
    text = " ".join(args.text).strip()
    if not text:
        return 1
    cfg = load_config()
    req = urllib.request.Request(
        "http://127.0.0.1:%d/api/quick" % cfg["local_port"],
        data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            res = json.load(r)
    except urllib.error.HTTPError as e:
        print("Ошибка: %s" % json.load(e).get("error"), file=sys.stderr)
        return 1
    except OSError:
        # Service is down: write straight to the database; it syncs once plannerd runs again.
        res = quick_add(Store(DATA_DIR / "planner.db"), text)
    print(res["summary"])
    return 0


def cmd_reset_token(args):
    path = CONFIG_DIR / "config.json"
    cfg = load_config()
    cfg["token"] = secrets.token_urlsafe(24)
    path.write_text(json.dumps(cfg, indent=2))
    (CONFIG_DIR / "cert.pem").unlink(missing_ok=True)
    (CONFIG_DIR / "key.pem").unlink(missing_ok=True)
    print("Новый ключ и сертификат созданы. Перезапусти службу и заново сопряги телефон.")


def main():
    p = argparse.ArgumentParser(prog="plannerd")
    sub = p.add_subparsers(dest="cmd")
    serve = sub.add_parser("serve", help="run the server (default)")
    serve.add_argument("--server", metavar="HOST:PORT",
                       help="server mode behind a TLS reverse proxy: plain HTTP here, token always required")
    pair = sub.add_parser("pair", help="show pairing QR code")
    pair.add_argument("--url", help="public HTTPS address of a server-mode plannerd")
    sub.add_parser("reset-token", help="revoke all paired phones")
    add = sub.add_parser("add", help='quick add, e.g. plannerd add "завтра 18:00 занятие"')
    add.add_argument("text", nargs="+")
    args = p.parse_args()
    if args.cmd is None:
        args.server = None
    sys.exit({"pair": cmd_pair, "reset-token": cmd_reset_token, "add": cmd_add}.get(args.cmd, cmd_serve)(args))


if __name__ == "__main__":
    main()
