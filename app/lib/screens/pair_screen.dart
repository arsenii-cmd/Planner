import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../sync.dart';

class PairScreen extends StatelessWidget {
  const PairScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final pair = sync.pair;
          if (pair == null) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.qr_code_scanner, size: 72),
                const SizedBox(height: 16),
                const Text(
                  'На компьютере выполни:\nplannerd pair (по локальной сети)\n'
                  'или plannerd cloud-pair --url … --token … (через интернет)\n\n'
                  'и отсканируй QR-код.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Сканировать QR'),
                  onPressed: () => _scan(context),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _manualEntry(context),
                  child: const Text('Ввести вручную'),
                ),
              ]),
            );
          }
          final last = sync.lastSync == null
              ? 'ещё не было'
              : DateFormat('d MMM, HH:mm:ss', 'ru_RU').format(sync.lastSync!);
          final offlineText = pair.isCloud
              ? 'Сервер недоступен (изменения сохранятся и уйдут позже)'
              : 'Ноут не в сети (изменения сохранятся и уйдут позже)';
          final status = switch (sync.state) {
            SyncState.syncing => 'Синхронизация…',
            SyncState.ok => 'Синхронизировано',
            SyncState.offline => offlineText,
            SyncState.error => 'Ошибка: ${sync.error}',
            _ => 'Ожидание',
          };
          return ListView(padding: const EdgeInsets.all(16), children: [
            ListTile(
              leading: Icon(pair.isCloud ? Icons.cloud_outlined : Icons.laptop),
              title: Text(pair.name),
              subtitle: Text(pair.isCloud ? pair.url! : (sync.host ?? pair.hosts.join(', '))),
            ),
            ListTile(leading: const Icon(Icons.info_outline), title: Text(status)),
            ListTile(leading: const Icon(Icons.history), title: Text('Последняя синхронизация: $last')),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text('Синхронизировать сейчас'),
              onPressed: sync.state == SyncState.syncing ? null : sync.syncNow,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Сопрячь заново'),
              onPressed: () => _scan(context),
            ),
            TextButton(onPressed: sync.unpair, child: const Text('Отвязать')),
          ]);
        },
      ),
    );
  }

  Future<void> _scan(BuildContext context) async {
    final info = await Navigator.of(context).push<PairInfo>(
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (info != null) await SyncService.instance.setPair(info);
  }

  Future<void> _manualEntry(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вставить пейлоад сопряжения'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'JSON, который печатает plannerd pair / cloud-pair',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Сопрячь'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    final info = PairInfo.fromQr(result.trim());
    if (info == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось разобрать пейлоад')),
        );
      }
      return;
    }
    await SyncService.instance.setPair(info);
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR-код с компьютера')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final code in capture.barcodes) {
            final info = PairInfo.fromQr(code.rawValue ?? '');
            if (info != null) {
              _done = true;
              Navigator.pop(context, info);
              return;
            }
          }
        },
      ),
    );
  }
}
