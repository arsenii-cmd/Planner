import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto.dart';
import 'db.dart';
import 'models.dart';
import 'reminders.dart';

class PairInfo {
  PairInfo({
    required this.name,
    this.hosts = const [],
    this.port,
    required this.token,
    this.fp,
    this.url,
    this.key,
  });

  final String name;

  // LAN mode (paired via `plannerd pair`, no `url`): candidate addresses + port on the
  // home network, plus the pinned certificate fingerprint.
  final List<String> hosts;
  final int? port;
  final String? fp;

  final String token;

  // Cloud mode (paired via `plannerd cloud-pair`): one fixed HTTPS address, CA-signed
  // certificate (not pinned), and the AES-256 key (base64) that encrypts everything
  // synced through it - the server itself never sees this key.
  final String? url;
  final String? key;

  bool get isCloud => url != null;

  /// Payload of the QR code printed by `plannerd pair` (LAN or --url) or `plannerd cloud-pair`.
  static PairInfo? fromQr(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['planner'] == null || j['token'] == null) return null;
      if (j['url'] != null) {
        return PairInfo(
          name: (j['name'] ?? 'сервер') as String,
          token: j['token'] as String,
          url: j['url'] as String,
          key: j['key'] as String?,
        );
      }
      if (j['hosts'] == null || j['port'] == null) return null;
      return PairInfo(
        name: (j['name'] ?? 'laptop') as String,
        hosts: (j['hosts'] as List).cast<String>(),
        port: (j['port'] as num).toInt(),
        token: j['token'] as String,
        fp: j['fp'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => isCloud
      ? {'planner': 3, 'name': name, 'url': url, 'token': token, 'key': key}
      : {'planner': 2, 'name': name, 'hosts': hosts, 'port': port, 'token': token, 'fp': fp};
}

enum SyncState { unpaired, idle, syncing, ok, offline, error }

class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  PairInfo? pair;
  String? host; // last address that answered (LAN mode only)
  int seq = 0;
  DateTime? lastSync;
  SyncState state = SyncState.unpaired;
  String? error;

  Timer? _timer;
  http.Client? _client;
  CloudCrypto? _cryptoCache;
  bool _listening = false;
  Timer? _debounce;
  Future<void>? _running;

  bool get isCloud => pair?.isCloud ?? false;

  /// Non-null only for a cloud pairing - the key that decrypts/encrypts everything
  /// that goes over `/api/sync`. Null for LAN mode, where nothing is encrypted here
  /// (the wire is already TLS with a pinned certificate inside the home network).
  CloudCrypto? get _crypto {
    final key = pair?.key;
    if (key == null) return null;
    return _cryptoCache ??= CloudCrypto(base64.decode(key));
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('pair');
    pair = raw == null ? null : PairInfo.fromQr(raw);
    _cryptoCache = null;
    host = prefs.getString('host');
    seq = prefs.getInt('seq') ?? 0;
    final last = prefs.getInt('lastSync');
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    state = pair == null ? SyncState.unpaired : SyncState.idle;
    if (!_listening) {
      LocalDb.instance.addListener(_onLocalChange);
      _listening = true;
    }
    notifyListeners();
  }

  Future<void> setPair(PairInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pair', jsonEncode(info.toJson()));
    await prefs.remove('host');
    // A new laptop/server (or reset database) — pull everything again.
    await prefs.setInt('seq', 0);
    pair = info;
    _client = null;
    _cryptoCache = null;
    host = null;
    seq = 0;
    state = SyncState.idle;
    notifyListeners();
    await syncNow();
  }

  Future<void> unpair() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pair');
    await prefs.remove('host');
    pair = null;
    _client = null;
    _cryptoCache = null;
    host = null;
    state = SyncState.unpaired;
    notifyListeners();
  }

  /// Sync every 30 s while the app is in the foreground.
  void startPeriodic() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    syncNow();
  }

  void stopPeriodic() {
    _timer?.cancel();
    _timer = null;
  }

  void _onLocalChange() {
    Reminders.reschedule();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), syncNow);
  }

  Future<void> syncNow() {
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  /// HTTPS client. LAN mode trusts only the certificate pinned at pairing time (there is
  /// no CA behind a self-signed cert); cloud mode uses ordinary CA validation against the
  /// server's Let's Encrypt certificate and must NOT skip it.
  http.Client get _http {
    if (_client != null) return _client!;
    if (isCloud) {
      return _client = IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 10));
    }
    return _client = IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..badCertificateCallback = (cert, host, port) =>
            pair?.fp != null && sha256.convert(cert.der).toString() == pair!.fp,
    );
  }

  Uri _url(String h, String path) =>
      isCloud ? Uri.parse('${pair!.url}/api/$path') : Uri.parse('https://$h:${pair!.port}/api/$path');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${pair!.token}',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Future<bool> _ping(String h) async {
    try {
      final r = await _http
          .get(_url(h, 'ping'))
          .timeout(const Duration(seconds: 2));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _discover() async {
    nsd.Discovery? discovery;
    try {
      discovery = await nsd.startDiscovery('_planner._tcp', ipLookupType: nsd.IpLookupType.v4);
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(deadline)) {
        for (final s in discovery.services) {
          for (final a in s.addresses ?? const []) {
            if (await _ping(a.address)) return a.address;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('mDNS discovery failed: $e');
    } finally {
      if (discovery != null) await nsd.stopDiscovery(discovery);
    }
    return null;
  }

  /// LAN-mode host lookup only; cloud mode has one fixed address and skips this entirely.
  Future<String?> _findHost() async {
    final candidates = <String>{?host, ...pair!.hosts};
    for (final h in candidates) {
      if (await _ping(h)) return h;
    }
    return _discover();
  }

  Future<void> _sync() async {
    if (pair == null) return;
    if (!isCloud && pair!.fp == null) {
      state = SyncState.error;
      error = 'Связь теперь зашифрована — сопряги заново (plannerd pair)';
      notifyListeners();
      return;
    }
    state = SyncState.syncing;
    notifyListeners();
    try {
      String h;
      if (isCloud) {
        h = pair!.url!;
      } else {
        final found = await _findHost();
        if (found == null) {
          state = SyncState.offline;
          return;
        }
        h = found;
        if (h != host) {
          host = h;
          (await SharedPreferences.getInstance()).setString('host', h);
        }
      }

      final dirty = await LocalDb.instance.dirty();
      var body = await _post(h, seq, dirty);
      // Server database was recreated: its counter is behind ours, pull everything.
      if ((body['seq'] as num).toInt() < seq) {
        body = await _post(h, 0, const []);
      }
      final changes = await Future.wait(
        (body['changes'] as List).map((e) => Item.fromWire(e as Map<String, dynamic>, _crypto)),
      );
      await LocalDb.instance.markClean(dirty);
      // Applying remote changes notifies listeners; don't let that trigger another sync.
      LocalDb.instance.removeListener(_onLocalChange);
      try {
        await LocalDb.instance.applyRemote(changes);
      } finally {
        LocalDb.instance.addListener(_onLocalChange);
      }

      seq = (body['seq'] as num).toInt();
      lastSync = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('seq', seq);
      await prefs.setInt('lastSync', lastSync!.millisecondsSinceEpoch);
      state = SyncState.ok;
      error = null;
      await Reminders.reschedule();
    } on _AuthError {
      state = SyncState.error;
      error = isCloud ? 'Сервер не принял ключ — сопряги заново' : 'Ноут не принял ключ — сопряги заново';
    } on SocketException {
      state = SyncState.offline;
    } on TimeoutException {
      state = SyncState.offline;
    } catch (e) {
      state = SyncState.error;
      error = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _post(String h, int since, List<Item> changes) async {
    final wire = await Future.wait(changes.map((c) => c.toWire(_crypto)));
    final r = await _http
        .post(
          _url(h, 'sync'),
          headers: _headers,
          body: jsonEncode({'since': since, 'changes': wire}),
        )
        .timeout(Duration(seconds: isCloud ? 20 : 10));
    if (r.statusCode == 401) throw _AuthError();
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }
}

class _AuthError implements Exception {}
