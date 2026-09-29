# Planner

**English** · [Русский](README.ru.md)

A calendar, day tasks and quick notes that sync between a Linux desktop and an
Android phone over the local network — no cloud account, no third-party server.
The desktop half is a small Python daemon over SQLite; the phone half is a
Flutter app that pairs by scanning a QR code.

Everything is kept on your own machines: the phone talks to the daemon directly
over HTTPS on the LAN, pinning the daemon's self-signed certificate from the
pairing QR. Nothing leaves the network.

## What is in here

| Path | What it is |
| --- | --- |
| `server/plannerd.py` | The sync daemon: JSON API, SQLite storage, mDNS announce, reminder notifications |
| `server/quickparse.py` | Russian free-text parser: `завтра 18:00 занятие` → an event tomorrow at 18:00 |
| `server/planner-add` | Quick-add prompt for a floating terminal window (bound to `SUPER+P`) |
| `server/plannerd.service` | systemd user unit for the daemon |
| `app/` | The Flutter app: calendar, tasks, notes, background sync, home-screen widget ([app/README.md](app/README.md)) |

## Server

Requires Python 3.11+ and nothing else; `zeroconf` is optional and only adds
mDNS discovery, `qrencode` only draws the pairing QR in the terminal.

```sh
install -Dm755 server/plannerd.py ~/.local/bin/plannerd
install -Dm644 server/quickparse.py ~/.local/bin/quickparse.py
install -Dm644 server/plannerd.service ~/.config/systemd/user/plannerd.service
systemctl --user enable --now plannerd
```

State lives in `~/.local/share/planner/planner.db`; the config, the access token
and the TLS certificate in `~/.config/planner/`. The token is generated on first
run — it is never in this repository, and `plannerd reset-token` revokes every
paired phone.

```sh
plannerd pair             # QR code + host, port and token in plain text
plannerd add "завтра 18:00 занятие // взять тетрадь"
plannerd reset-token      # unpair everything
```

The daemon listens on TCP 47210 (HTTPS, token required) for the LAN and on
`127.0.0.1:47211` (plain HTTP, no token) for local desktop widgets. Open 47210
if you run a firewall.

## Server mode (database on a server)

To keep the database on an always-on server instead of the desktop, run plannerd
behind a TLS reverse proxy with a real certificate:

```sh
install -Dm644 server/plannerd.py server/quickparse.py -t /opt/planner/
install -Dm644 server/plannerd-server.service /etc/systemd/system/plannerd-server.service
systemctl enable --now plannerd-server
```

The daemon then listens on `127.0.0.1:47212` over plain HTTP and requires the token
from every client, loopback included (the proxy connects from there). No mDNS, no
desktop notifications. It stores only end-to-end encrypted items: quick add and any
item without an encrypted `blob` are refused with 400, so nothing lands on the server
in the clear. Point the proxy at it, e.g. for Caddy:

```
planner.example.com {
    reverse_proxy /api/* 127.0.0.1:47212
}
```

Pair a phone against the public address:

```sh
XDG_CONFIG_HOME=/var/lib/planner/config python3 /opt/planner/plannerd.py pair --url https://planner.example.com
```

The QR payload is then `{"planner":2,"name":…,"url":"https://…","token":…}` — a `url`
instead of `hosts`/`port`/`fp`. The certificate is checked the normal way (a public CA),
so there is nothing to pin. Moving an existing database: stop both daemons, copy
`planner.db` to `/var/lib/planner/`, start the server, re-pair the phone.

## App

```sh
cd app
flutter pub get
flutter build apk --release
```

Then open the app, tap pair and scan what `plannerd pair` prints. The app finds
the daemon again by mDNS when the laptop's address changes, syncs in the
background, raises local notifications for events with a reminder set, and can
put today's list on the home screen as a widget.

## Headless copy (local-only)

An always-on box without a desktop (say, one running a voice assistant) can keep its own
decrypted copy of a cloud-paired Planner and serve it only to programs on that machine:

```bash
plannerd serve --local-only
```

It listens on `127.0.0.1:47211` only: no LAN port, no mDNS, no desktop notifications (the
daily carry-over of unfinished tasks still runs). Give it the desktop's `cloud` section
(`url`, `token`, `key`) with `"seq": 0`, `"enabled": true` and its own `"device"`
(e.g. `"homebox"`), so its changes are signed with its name rather than `desktop`.
`GET /api/items?q=text` finds items by title or text, case-insensitively.

## Quick-add syntax

`quickparse.py` turns one line of Russian into an item. A time makes it an
event, otherwise it becomes a task on the given day.

```
завтра 18:00 занятие               event tomorrow at 18:00
в пятницу с 10 до 11:30 созвон     event on the coming Friday, 10:00–11:30
25.09 в 9 стоматолог               event on 25 September at 09:00
18:00 2 недели занятие             a weekly series of 2
купить хлеб                        a task on the default day
18:00 занятие // взять тетрадь     everything after // becomes the description
```

## Sync model

Every item carries `updated_at` in milliseconds and the id of the device that
wrote it. Both sides exchange everything newer than the sequence number they
last saw; on a conflict the later write wins, and a tie is broken by device id.
Deletes are tombstones, so they propagate like any other change.

## License

MIT — see [LICENSE](LICENSE). The bundled Adwaita Mono font is under the SIL
Open Font License, see `app/assets/fonts/OFL-LICENSE.txt`.
