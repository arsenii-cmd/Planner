import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'db.dart';
import 'models.dart';
import 'reminders.dart';
import 'sync.dart';

const _provider = 'dev.arco.planner.TodayWidgetProvider';

/// Feeds the "Сегодня" home-screen widget (android TodayWidgetProvider).
///
/// Data for the next 7 days is stored so the widget still shows the right day after midnight,
/// even if the app hasn't run since.
class WidgetBridge {
  WidgetBridge._();

  static Future<void> update() async {
    await initializeDateFormatting('ru_RU');
    final now = DateTime.now();
    final items = await LocalDb.instance.range(dateKey(now), dateKey(now.add(const Duration(days: 6))));
    final days = <String, Object>{};
    for (var i = 0; i < 7; i++) {
      final d = now.add(Duration(days: i));
      final key = dateKey(d);
      final today = items.where((it) => it.date == key).toList()
        // events first by time, then open tasks, done tasks last
        ..sort((a, b) {
          int rank(Item x) => x.kind == ItemKind.event ? 0 : (x.done ? 2 : 1);
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : (a.startTime ?? '99:99').compareTo(b.startTime ?? '99:99');
        });
      days[key] = {
        'label': DateFormat('EEEE, d MMMM', 'ru_RU').format(d),
        'items': [
          for (final it in today)
            {
              'id': it.id,
              'kind': it.kind.name,
              'title': it.displayTitle,
              'time': it.startTime ?? '',
              'done': it.done,
            },
        ],
      };
    }
    await HomeWidget.saveWidgetData<String>('days', jsonEncode(days));
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
  }
}

/// Runs in a background isolate when a task checkbox in the widget is tapped (planner://toggle?id=…).
@pragma('vm:entry-point')
Future<void> widgetInteraction(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  if (uri?.host != 'toggle') return;
  final id = uri!.queryParameters['id'];
  if (id == null) return;
  final item = await LocalDb.instance.get(id);
  if (item == null) return;
  item.done = !item.done;
  await LocalDb.instance.save(item);
  await WidgetBridge.update();
  try {
    await SyncService.instance.load();
    await SyncService.instance.syncNow();
    await Reminders.reschedule();
    await WidgetBridge.update();
  } catch (e) {
    debugPrint('widget sync failed: $e');
  }
}
