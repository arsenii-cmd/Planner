import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../db.dart';
import '../models.dart';
import '../theme.dart';
import 'edit_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  /// Bumped from outside (widget "+" button) to open the add sheet for today.
  static final addRequests = ValueNotifier<int>(0);

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  // Static so the chosen day survives switching to the notes tab (the page is rebuilt).
  static DateTime _focused = DateTime.now();
  static DateTime _selected = DateTime.now();

  Map<String, List<Item>> _byDate = {};
  PageController? _pages;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.addListener(_load);
    CalendarScreen.addRequests.addListener(_onAddRequest);
    _load();
  }

  @override
  void dispose() {
    LocalDb.instance.removeListener(_load);
    CalendarScreen.addRequests.removeListener(_onAddRequest);
    super.dispose();
  }

  void _onAddRequest() {
    _goToday();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _add();
    });
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

  void _select(DateTime day) {
    HapticFeedback.selectionClick();
    setState(() {
      _selected = day;
      _focused = day;
    });
  }

  void _goToday() {
    _select(DateTime.now());
    _load();
  }

  Future<void> _add() async {
    final kind = await showModalBottomSheet<ItemKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              DateFormat('EEEE, d MMMM', 'ru_RU').format(_selected),
              style: const TextStyle(color: P.subtext1),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _KindTile(
                  icon: Icons.event_rounded,
                  label: 'Событие',
                  hint: 'со временем',
                  onTap: () => Navigator.pop(context, ItemKind.event),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _KindTile(
                  icon: Icons.task_alt_rounded,
                  label: 'Задача',
                  hint: 'на этот день',
                  onTap: () => Navigator.pop(context, ItemKind.task),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    if (kind == null || !mounted) return;
    await openEditor(
      context,
      Item(kind: kind, date: dateKey(_selected), remind: kind == ItemKind.event ? 15 : null),
      isNew: true,
    );
  }

  Future<void> _deleteWithUndo(Item item) async {
    HapticFeedback.mediumImpact();
    await LocalDb.instance.remove(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('«${item.displayTitle}» удалено'),
        action: SnackBarAction(
          label: 'Вернуть',
          onPressed: () {
            item.deleted = false;
            LocalDb.instance.save(item);
          },
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final key = dateKey(_selected);
    final day = _byDate[key] ?? const <Item>[];
    final events = day.where((i) => i.kind == ItemKind.event).toList();
    final tasks = day.where((i) => i.kind == ItemKind.task).toList();
    final now = DateTime.now();
    final isThisMonth = _focused.year == now.year && _focused.month == now.month;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add_rounded, size: 30),
      ),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                child: Column(children: [
                  _MonthHeader(
                    month: _focused,
                    showToday: !(isThisMonth && isSameDay(_selected, now)),
                    onPrev: () => _pages?.previousPage(
                        duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic),
                    onNext: () => _pages?.nextPage(
                        duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic),
                    onToday: _goToday,
                  ),
                  TableCalendar<Item>(
                    locale: 'ru_RU',
                    firstDay: DateTime(2000),
                    lastDay: DateTime(2100),
                    focusedDay: _focused,
                    headerVisible: false,
                    rowHeight: 50,
                    daysOfWeekHeight: 28,
                    sixWeekMonthsEnforced: true,
                    startingDayOfWeek: StartingDayOfWeek.monday,
                    availableCalendarFormats: const {CalendarFormat.month: 'Месяц'},
                    pageAnimationDuration: const Duration(milliseconds: 350),
                    pageAnimationCurve: Curves.easeOutCubic,
                    onCalendarCreated: (c) => _pages = c,
                    selectedDayPredicate: (d) => isSameDay(d, _selected),
                    eventLoader: (d) => _byDate[dateKey(d)] ?? const [],
                    onDaySelected: (sel, _) => _select(sel),
                    onPageChanged: (foc) {
                      setState(() => _focused = foc);
                      _load();
                    },
                    calendarBuilders: CalendarBuilders(
                      dowBuilder: (context, d) => Center(
                        child: Text(
                          DateFormat.E('ru_RU').format(d).replaceAll('.', '').toUpperCase(),
                          style: TextStyle(
                            fontFamily: kFont,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: d.weekday >= 6 ? P.accent.withValues(alpha: 0.8) : P.subtext1,
                          ),
                        ),
                      ),
                      defaultBuilder: (context, d, _) => _DayCell(day: d),
                      outsideBuilder: (context, d, _) => _DayCell(day: d, outside: true),
                      todayBuilder: (context, d, _) => _DayCell(day: d, today: true),
                      selectedBuilder: (context, d, _) =>
                          _DayCell(day: d, selected: true, today: isSameDay(d, DateTime.now())),
                      markerBuilder: (context, d, items) {
                        if (items.isEmpty) return null;
                        final selected = isSameDay(d, _selected);
                        return Positioned(
                          bottom: 7,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            for (final it in items.take(3))
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 250),
                                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: (selected ? P.base : (it.kind == ItemKind.event ? P.accent : P.sand))
                                      .withValues(alpha: it.done ? 0.35 : 1),
                                ),
                              ),
                          ]),
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            // Only re-animate when the day changes; edits inside the day update in place.
            child: _DayPanel(
              key: ValueKey(key),
              date: _selected,
              events: events,
              tasks: tasks,
              onDelete: _deleteWithUndo,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ]),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.showToday,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final bool showToday;
  final VoidCallback onPrev, onNext, onToday;

  @override
  Widget build(BuildContext context) {
    final title = DateFormat('LLLL yyyy', 'ru_RU').format(month).toUpperCase();
    return SizedBox(
      height: 48,
      child: Row(children: [
        _RoundButton(icon: Icons.chevron_left_rounded, onTap: onPrev),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(anim), child: child),
            ),
            child: Text(
              title,
              key: ValueKey(title),
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: kFont, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 1),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: showToday
              ? Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _RoundButton(icon: Icons.today_rounded, onTap: onToday, accent: true),
                )
              : const SizedBox.shrink(),
        ),
        _RoundButton(icon: Icons.chevron_right_rounded, onTap: onNext),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap, this.accent = false});

  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: P.surface0, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: accent ? P.accent : P.text),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, this.outside = false, this.today = false, this.selected = false});

  final DateTime day;
  final bool outside, today, selected;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected ? P.accent : (today ? P.surface1 : Colors.transparent);
    final Color fg = selected
        ? P.base
        : (today ? P.accent : (outside ? P.subtext1.withValues(alpha: 0.6) : P.text));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: today && !selected ? Border.all(color: P.accent.withValues(alpha: 0.6)) : null,
      ),
      alignment: const Alignment(0, -0.3),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 200),
        style: TextStyle(
          fontFamily: kFont,
          fontSize: 15,
          fontWeight: selected || today ? FontWeight.w700 : FontWeight.w400,
          color: fg,
        ),
        child: Text('${day.day}'),
      ),
    );
  }
}

class _KindTile extends StatelessWidget {
  const _KindTile({required this.icon, required this.label, required this.hint, required this.onTap});

  final IconData icon;
  final String label, hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: P.surface0, borderRadius: BorderRadius.circular(kRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: P.accent, size: 28),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(hint, style: const TextStyle(color: P.subtext1, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _DayPanel extends StatelessWidget {
  const _DayPanel({super.key, required this.date, required this.events, required this.tasks, required this.onDelete});

  final DateTime date;
  final List<Item> events, tasks;
  final void Function(Item) onDelete;

  @override
  Widget build(BuildContext context) {
    final done = tasks.where((t) => t.done).length;
    var i = 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text(
              DateFormat('EEEE, d MMMM', 'ru_RU').format(date),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          if (tasks.isNotEmpty)
            Text('$done/${tasks.length}', style: const TextStyle(color: P.subtext1, fontWeight: FontWeight.w700)),
        ]),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: tasks.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: done / tasks.length),
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 4,
                        backgroundColor: P.surface0,
                        color: P.accent,
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 14),
        if (events.isEmpty && tasks.isEmpty)
          const EnterAnimation(child: _EmptyDay())
        else ...[
          for (final e in events)
            EnterAnimation(
              key: ValueKey('e-${e.id}'),
              index: i++,
              child: _Swipe(item: e, onDelete: onDelete, child: _EventCard(item: e)),
            ),
          for (final t in tasks)
            EnterAnimation(
              key: ValueKey('t-${t.id}'),
              index: i++,
              child: _Swipe(item: t, onDelete: onDelete, child: _TaskCard(item: t)),
            ),
        ],
      ]),
    );
  }
}

class _Swipe extends StatelessWidget {
  const _Swipe({required this.item, required this.onDelete, required this.child});

  final Item item;
  final void Function(Item) onDelete;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('dismiss-${item.id}-${item.updatedAt}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDelete(item),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          decoration: BoxDecoration(color: P.accentDeep, borderRadius: BorderRadius.circular(kRadius)),
          child: const Icon(Icons.delete_outline_rounded, color: P.text),
        ),
        child: child,
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.item});
  final Item item;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => openEditor(context, item),
      child: Container(
        decoration: BoxDecoration(color: P.mantle, borderRadius: BorderRadius.circular(kRadius)),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(children: [
            Container(width: 4, color: P.accent),
            const SizedBox(width: 12),
            SizedBox(
              width: 56,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(item.startTime ?? 'весь', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                // An empty second line would push the time above the title's centre line.
                if (item.endTime != null || item.startTime == null)
                  Text(item.endTime ?? 'день', style: const TextStyle(color: P.subtext1, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(item.displayTitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    if (item.displaySubtitle.isNotEmpty)
                      Text(item.displaySubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: P.subtext1, fontSize: 13)),
                  ],
                ),
              ),
            ),
            if (item.series != null) const Icon(Icons.repeat_rounded, size: 18, color: P.subtext1),
            if (item.remind != null && item.startTime != null) ...[
              const SizedBox(width: 6),
              const Icon(Icons.notifications_active_rounded, size: 18, color: P.accent),
            ],
            const SizedBox(width: 14),
          ]),
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.item});
  final Item item;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () {
        HapticFeedback.lightImpact();
        item.done = !item.done;
        LocalDb.instance.save(item);
      },
      onLongPress: () => openEditor(context, item),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: item.done ? P.crust : P.mantle,
          borderRadius: BorderRadius.circular(kRadius),
        ),
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: item.done ? P.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: item.done ? P.accent : P.subtext1, width: 2),
            ),
            child: AnimatedScale(
              scale: item.done ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              child: const Icon(Icons.check_rounded, size: 18, color: P.base),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              style: TextStyle(
                fontFamily: kFont,
                fontSize: 15,
                color: item.done ? P.subtext1 : P.text,
                decoration: item.done ? TextDecoration.lineThrough : TextDecoration.none,
                decorationColor: P.subtext1,
              ),
              child: Text(item.displayTitle),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, color: P.subtext1),
            onPressed: () => openEditor(context, item),
          ),
        ]),
      ),
    );
  }
}

class _EmptyDay extends StatelessWidget {
  const _EmptyDay();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: P.surface0, width: 1.5),
      ),
      child: const Column(children: [
        Icon(Icons.wb_twilight_rounded, size: 34, color: P.surface2),
        SizedBox(height: 8),
        Text('Свободный день', style: TextStyle(color: P.subtext1)),
        Text('Нажми + чтобы добавить', style: TextStyle(color: P.subtext1, fontSize: 12)),
      ]),
    );
  }
}
