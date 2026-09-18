import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'models.dart';
import 'reminders.dart';

class PairInfo {
  PairInfo({required this.name, required this.hosts, required this.port, required this.token, this.fp});

  final String name;
  final List<String> hosts;
  final int port;
  final String token;

  /// SHA-256 of the laptop's TLS certificate (hex). Missing = paired before encryption.
  final String? fp;

  /// Payload of the QR code printed by `plannerd pair`.
  static PairInfo? fromQr(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['planner'] == null || j['token'] == null) return null;
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

  Map<String, dynamic> toJson() =>
      {'planner': 2, 'name': name, 'hosts': hosts, 'port': port, 'token': token, 'fp': fp};
}

enum SyncState { unpaired, idle, syncing, ok, offline, error }

class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  PairInfo? pair;
  String? host; // last address that answered
  int seq = 0;
  DateTime? lastSync;
  SyncState state = SyncState.unpaired;
  String? error;

  Timer? _timer;
  http.Client? _client;
  bool _listening = false;
  Timer? _debounce;
  Future<void>? _running;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('pair');
    pair = raw == null ? null : PairInfo.fromQr(raw);
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
    // A new laptop (or reset database) — pull everything again.
    await prefs.setInt('seq', 0);
    pair = info;
    _client = null;
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

  /// HTTPS client that trusts only the certificate pinned at pairing time.
  http.Client get _http {
    return _client ??= IOClient(
      HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        ..badCertificateCallback = (cert, host, port) =>
            pair?.fp != null && sha256.convert(cert.der).toString() == pair!.fp,
    );
  }

  Uri _url(String h, String path) => Uri.parse('https://$h:${pair!.port}/api/$path');

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

  Future<String?> _findHost() async {
    final candidates = <String>{?host, ...pair!.hosts};
    for (final h in candidates) {
      if (await _ping(h)) return h;
    }
    return _discover();
  }

  Future<void> _sync() async {
    if (pair == null) return;
    if (pair!.fp == null) {
      state = SyncState.error;
      error = 'Связь теперь зашифрована — сопряги заново (plannerd pair)';
      notifyListeners();
      return;
    }
    state = SyncState.syncing;
    notifyListeners();
    try {
      final h = await _findHost();
      if (h == null) {
        state = SyncState.offline;
        return;
      }
      if (h != host) {
        host = h;
        (await SharedPreferences.getInstance()).setString('host', h);
      }

      final dirty = await LocalDb.instance.dirty();
      var body = await _post(h, seq, dirty);
      // Server database was recreated: its counter is behind ours, pull everything.
      if ((body['seq'] as num).toInt() < seq) {
        body = await _post(h, 0, const []);
      }
      final changes = (body['changes'] as List)
          .map((e) => Item.fromJson(e as Map<String, dynamic>))
          .toList();
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
      error = 'Ноут не принял ключ — сопряги заново';
    } catch (e) {
      state = SyncState.error;
      error = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _post(String h, int since, List<Item> changes) async {
    final r = await _http
        .post(
          _url(h, 'sync'),
          headers: _headers,
          body: jsonEncode({'since': since, 'changes': changes.map((c) => c.toJson()).toList()}),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401) throw _AuthError();
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }
}

class _AuthError implements Exception {}
