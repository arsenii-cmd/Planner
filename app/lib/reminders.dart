import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'db.dart';
import 'models.dart';

/// Schedules local notifications for events that have a reminder.
/// Rebuilt from the local database after every change or sync.
class Reminders {
  Reminders._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Напоминания',
      channelDescription: 'Напоминания о событиях',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_notification',
      color: Color(0xFFFFB5A0),
    ),
  );

  static Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      debugPrint('timezone lookup failed: $e');
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
    );
    _ready = true;
  }

  /// Asks for the Android 13+ notification permission (foreground only).
  static Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> reschedule() async {
    await init();
    final now = DateTime.now();
    final items = await LocalDb.instance.remindable(
      dateKey(now.subtract(const Duration(days: 1))),
      dateKey(now.add(const Duration(days: 45))),
    );
    await _plugin.cancelAllPendingNotifications();
    var count = 0;
    for (final it in items) {
      final start = DateTime.parse('${it.date} ${it.startTime}:00');
      final fire = start.subtract(Duration(minutes: it.remind!));
      if (!fire.isAfter(now)) continue;
      // Android caps pending alarms per app; the nearest ones matter most.
      if (++count > 60) break;
      await _plugin.zonedSchedule(
        id: it.id.hashCode & 0x7fffffff,
        scheduledDate: tz.TZDateTime.from(fire, tz.local),
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        title: it.title.isEmpty && it.body.isEmpty ? 'Событие' : it.displayTitle,
        body: it.remind == 0 ? 'Сейчас, ${it.startTime}' : 'В ${it.startTime} (через ${_ago(it.remind!)})',
      );
    }
    await _scheduleSummaries(now);
  }

  static const summaryHour = 8;

  /// 08:00 summaries for the next 7 days, built from what is planned right now.
  static Future<void> _scheduleSummaries(DateTime now) async {
    final items = await LocalDb.instance.range(dateKey(now), dateKey(now.add(const Duration(days: 6))));
    for (var i = 0; i < 7; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
      final fire = DateTime(day.year, day.month, day.day, summaryHour);
      if (!fire.isAfter(now)) continue;
      final key = dateKey(day);
      final events = items.where((it) => it.date == key && it.kind == ItemKind.event).toList();
      final tasks = items.where((it) => it.date == key && it.kind == ItemKind.task && !it.done).toList();
      if (events.isEmpty && tasks.isEmpty) continue;
      final head = [
        if (events.isNotEmpty) '${events.length} ${_plural(events.length, 'событие', 'события', 'событий')}',
        if (tasks.isNotEmpty) '${tasks.length} ${_plural(tasks.length, 'задача', 'задачи', 'задач')}',
      ].join(', ');
      final lines = [
        for (final e in events) '${e.startTime ?? 'весь день'}  ${e.displayTitle}',
        for (final t in tasks) '☐ ${t.displayTitle}',
      ];
      await _plugin.zonedSchedule(
        id: 800000 + i,
        scheduledDate: tz.TZDateTime.from(fire, tz.local),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'summary',
            'Утренняя сводка',
            channelDescription: 'Список дел на день в 8:00',
            icon: 'ic_notification',
            color: const Color(0xFFFFB5A0),
            styleInformation: BigTextStyleInformation(lines.join('\n')),
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        title: 'Сегодня: $head',
        body: lines.take(3).join(' · '),
      );
    }
  }

  static String _plural(int n, String one, String few, String many) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }

  static String _ago(int minutes) {
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} дн.';
    if (minutes % 60 == 0) return '${minutes ~/ 60} ч';
    return '$minutes мин';
  }
}

/// Reminder choices shown in the editor (minutes before start).
const reminderOptions = <int?, String>{
  null: 'Без напоминания',
  0: 'В момент начала',
  5: 'За 5 минут',
  15: 'За 15 минут',
  30: 'За 30 минут',
  60: 'За 1 час',
  180: 'За 3 часа',
  1440: 'За 1 день',
};
