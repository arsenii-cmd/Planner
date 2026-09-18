import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../db.dart';
import '../models.dart';
import 'edit_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  Map<String, List<Item>> _byDate = {};

  @override
  void initState() {
    super.initState();
    LocalDb.instance.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    LocalDb.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    // The visible grid spans up to a week on each side of the month.
    final from = DateTime(_focused.year, _focused.month, 1).subtract(const Duration(days: 7));
    final to = DateTime(_focused.year, _focused.month + 1, 0).add(const Duration(days: 14));
    final items = await LocalDb.instance.range(dateKey(from), dateKey(to));
    final map = <String, List<Item>>{};
    for (final it in items) {
      map.putIfAbsent(it.date!, () => []).add(it);
    }
    if (mounted) setState(() => _byDate = map);
  }

  Future<void> _add() async {
    final kind = await showModalBottomSheet<ItemKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.event),
            title: const Text('Событие'),
            onTap: () => Navigator.pop(context, ItemKind.event),
          ),
          ListTile(
            leading: const Icon(Icons.check_box_outlined),
            title: const Text('Задача на день'),
            onTap: () => Navigator.pop(context, ItemKind.task),
          ),
        ]),
      ),
    );
    if (kind == null || !mounted) return;
    await openEditor(
      context,
      Item(kind: kind, date: dateKey(_selected), remind: kind == ItemKind.event ? 15 : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final day = _byDate[dateKey(_selected)] ?? const [];
    final events = day.where((i) => i.kind == ItemKind.event).toList();
    final tasks = day.where((i) => i.kind == ItemKind.task).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      body: Column(children: [
        TableCalendar<Item>(
          locale: 'ru_RU',
          firstDay: DateTime(2000),
          lastDay: DateTime(2100),
          focusedDay: _focused,
          startingDayOfWeek: StartingDayOfWeek.monday,
          availableCalendarFormats: const {CalendarFormat.month: 'Месяц'},
          selectedDayPredicate: (d) => isSameDay(d, _selected),
          eventLoader: (d) => _byDate[dateKey(d)] ?? const [],
          onDaySelected: (sel, foc) => setState(() {
            _selected = sel;
            _focused = foc;
          }),
          onPageChanged: (foc) {
            _focused = foc;
            _load();
          },
          headerStyle: const HeaderStyle(titleCentered: true, formatButtonVisible: false),
          calendarStyle: CalendarStyle(
            outsideDaysVisible: true,
            outsideTextStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.25)),
            todayDecoration: BoxDecoration(
              border: Border.all(color: scheme.primary),
              shape: BoxShape.circle,
            ),
            todayTextStyle: TextStyle(color: scheme.primary),
            selectedDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            selectedTextStyle: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.bold),
            markerDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            markersMaxCount: 3,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: day.isEmpty
              ? Center(
                  child: Text('Ничего не запланировано',
                      style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5))),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                  if (events.isNotEmpty) const _Header('События'),
                  for (final e in events)
                    ListTile(
                      leading: Icon(Icons.event, color: scheme.primary),
                      title: Text(e.title.isEmpty ? 'Без названия' : e.title),
                      trailing: e.remind != null && e.startTime != null
                          ? Icon(Icons.notifications_active_outlined, size: 18, color: scheme.primary)
                          : null,
                      subtitle: e.startTime == null
                          ? (e.body.isEmpty ? null : Text(e.body, maxLines: 1, overflow: TextOverflow.ellipsis))
                          : Text([e.startTime, e.endTime].whereType<String>().join(' – ')),
                      onTap: () => openEditor(context, e),
                    ),
                  if (tasks.isNotEmpty) const _Header('Задачи'),
                  for (final t in tasks)
                    CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      value: t.done,
                      title: Text(
                        t.title.isEmpty ? 'Без названия' : t.title,
                        style: t.done
                            ? TextStyle(
                                decoration: TextDecoration.lineThrough,
                                color: scheme.onSurface.withValues(alpha: 0.5))
                            : null,
                      ),
                      secondary: IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => openEditor(context, t),
                      ),
                      onChanged: (v) {
                        t.done = v ?? false;
                        LocalDb.instance.save(t);
                      },
                    ),
                ]),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
      );
}
