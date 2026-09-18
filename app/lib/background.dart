import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'reminders.dart';
import 'sync.dart';

const _taskName = 'planner-sync';

/// Runs in a background isolate started by Android WorkManager (~every 15 min).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await SyncService.instance.load();
      await SyncService.instance.syncNow();
      await Reminders.reschedule();
    } catch (e) {
      debugPrint('background sync failed: $e');
    }
    return true;
  });
}

Future<void> registerBackgroundSync() async {
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskName,
    _taskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.unmetered),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
