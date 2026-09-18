import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../db.dart';
import '../models.dart';
import '../reminders.dart';
import '../theme.dart';

Future<void> openEditor(BuildContext context, Item item, {bool isNew = false}) {
  return Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => EditScreen(item: item, isNew: isNew)));
}

/// 1 неделя, 2 недели, 5 недель.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

enum _Scope { one, all }

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.item, this.isNew = false});
  final Item item;
  final bool isNew;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _body = TextEditingController(text: widget.item.body);
  late String? _date = widget.item.date;
  late String? _start = widget.item.startTime;
  late String? _end = widget.item.endTime;
  late int? _remind = widget.item.remind;
  RepeatUnit? _repeat;
  int _repeatCount = 2;

  static const _maxRepeat = {RepeatUnit.week: 52, RepeatUnit.month: 24};

  ItemKind get _kind => widget.item.kind;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  String get _heading => switch (_kind) {
        ItemKind.event => 'Событие',
        ItemKind.task => 'Задача',
        ItemKind.note => 'Заметка',
      };

  Future<void> _pickDate() async {
    final initial = _date == null ? DateTime.now() : parseDateKey(_date!);
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = dateKey(d));
  }

  Future<String?> _pickTime(String? current) async {
    final parts = (current ?? '09:00').split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null) return current;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<_Scope?> _askScope(String action) {
    return showDialog<_Scope>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$action повторяющееся событие'),
        content: const Text('Это событие — часть серии.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, _Scope.one), child: const Text('Только это')),
          FilledButton(onPressed: () => Navigator.pop(context, _Scope.all), child: const Text('Всю серию')),
        ],
      ),
    );
  }

  Future<void> _save() async {
    var title = _title.text.trim();
    var body = _body.text.trim();
    if (title.isEmpty && body.isEmpty) {
      Navigator.pop(context);
      return;
    }
    if (title.isEmpty) {
      // Typed only into the description: its first line becomes the title.
      final lines = body.split('\n');
      title = lines.first.trim();
      body = lines.skip(1).join('\n').trim();
    }
    final it = widget.item
      ..title = title
      ..body = body
      ..date = _kind == ItemKind.note ? null : _date
      ..startTime = _kind == ItemKind.event ? _start : null
      ..endTime = _kind == ItemKind.event && _start != null ? _end : null
      ..remind = _kind == ItemKind.event && _start != null ? _remind : null;

    if (widget.isNew && _repeat != null && _repeatCount > 1 && it.date != null) {
      // N occurrences in one series, the chosen day included.
      it.series = const Uuid().v4();
      await LocalDb.instance.saveAll([
        for (var i = 0; i < _repeatCount; i++)
          i == 0 ? it : it.copyWith(id: const Uuid().v4(), date: shiftDate(it.date!, _repeat!, i)),
      ]);
    } else if (!widget.isNew && it.series != null) {
      final scope = await _askScope('Изменить');
      if (scope == null) return;
      if (scope == _Scope.one) {
        await LocalDb.instance.save(it);
      } else {
        // Same text/time/reminder everywhere; each occurrence keeps its own date and done flag.
        final others = (await LocalDb.instance.seriesItems(it.series!)).where((o) => o.id != it.id);
        await LocalDb.instance.saveAll([
          it,
          for (final o in others)
            o
              ..title = it.title
              ..body = it.body
              ..startTime = it.startTime
              ..endTime = it.endTime
              ..remind = it.remind,
        ]);
      }
    } else {
      await LocalDb.instance.save(it);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    if (widget.isNew) {
      Navigator.pop(context);
      return;
    }
    final series = widget.item.series;
    if (series != null) {
      final scope = await _askScope('Удалить');
      if (scope == null) return;
      if (scope == _Scope.one) {
        await LocalDb.instance.remove(widget.item);
      } else {
        final all = await LocalDb.instance.seriesItems(series);
        await LocalDb.instance.saveAll([for (final o in all) o..deleted = true]);
      }
      if (mounted) Navigator.pop(context);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить ${_heading.toLowerCase()}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    await LocalDb.instance.remove(widget.item);
    if (mounted) Navigator.pop(context);
  }

  Widget _repeatSection() {
    final unit = _repeat;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _Label(icon: Icons.repeat_rounded, text: 'Повтор'),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<RepeatUnit?>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            backgroundColor: P.surface0,
            selectedBackgroundColor: P.accent,
            selectedForegroundColor: P.base,
            foregroundColor: P.text,
            side: const BorderSide(color: P.surface1),
            textStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w700),
          ),
          segments: const [
            ButtonSegment(value: null, label: Text('Нет')),
            ButtonSegment(value: RepeatUnit.week, label: Text('Неделя')),
            ButtonSegment(value: RepeatUnit.month, label: Text('Месяц')),
          ],
          selected: {unit},
          onSelectionChanged: (v) => setState(() {
            _repeat = v.first;
            if (_repeat != null) _repeatCount = _repeatCount.clamp(2, _maxRepeat[_repeat]!);
          }),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: unit == null || _date == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(children: [
                  _StepButton(
                    icon: Icons.remove_rounded,
                    onTap: _repeatCount > 2 ? () => setState(() => _repeatCount--) : null,
                  ),
                  SizedBox(
                    width: 110,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                      child: Text(
                        unit == RepeatUnit.week
                            ? '$_repeatCount ${plural(_repeatCount, 'неделя', 'недели', 'недель')}'
                            : '$_repeatCount ${plural(_repeatCount, 'месяц', 'месяца', 'месяцев')}',
                        key: ValueKey('$unit$_repeatCount'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  _StepButton(
                    icon: Icons.add_rounded,
                    onTap: _repeatCount < _maxRepeat[unit]! ? () => setState(() => _repeatCount++) : null,
                  ),
                  Expanded(
                    child: Text(
                      'по ${DateFormat('d MMM', 'ru_RU').format(parseDateKey(shiftDate(_date!, unit, _repeatCount - 1)))}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: P.subtext1),
                    ),
                  ),
                ]),
              ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _date == null
        ? 'Выбрать дату'
        : DateFormat('EEEE, d MMMM y', 'ru_RU').format(parseDateKey(_date!));
    final isEvent = _kind == ItemKind.event;
    return Scaffold(
      appBar: AppBar(
        title: Text(_heading),
        actions: [
          if (!widget.isNew)
            IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete, tooltip: 'Удалить'),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded, size: 20),
              label: const Text('Готово', style: TextStyle(fontFamily: kFont, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        TextField(
          controller: _title,
          autofocus: widget.isNew,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontFamily: kFont, fontSize: 20, fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: switch (_kind) {
              ItemKind.event => 'Название события',
              ItemKind.task => 'Что сделать',
              ItemKind.note => 'Заголовок',
            },
            prefixIcon: const Icon(Icons.edit_rounded, color: P.accent, size: 20),
            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          ),
        ),
        const SizedBox(height: 12),
        if (_kind != ItemKind.note)
          EnterAnimation(
            child: _Section(children: [
              _Tap(icon: Icons.calendar_today_rounded, text: dateLabel, onTap: _pickDate),
              if (isEvent) ...[
                const Divider(height: 20),
                Row(children: [
                  const Icon(Icons.schedule_rounded, color: P.subtext0, size: 22),
                  const SizedBox(width: 14),
                  _Chip(
                    text: _start ?? 'Весь день',
                    active: _start != null,
                    onTap: () async {
                      final t = await _pickTime(_start);
                      setState(() => _start = t);
                    },
                  ),
                  if (_start != null) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('→', style: TextStyle(color: P.subtext1)),
                    ),
                    _Chip(
                      text: _end ?? 'конец',
                      active: _end != null,
                      onTap: () async {
                        final t = await _pickTime(_end ?? _start);
                        setState(() => _end = t);
                      },
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: P.subtext1),
                      tooltip: 'Весь день',
                      onPressed: () => setState(() {
                        _start = null;
                        _end = null;
                      }),
                    ),
                  ],
                ]),
              ],
              if (widget.item.series != null && !widget.isNew) ...[
                const Divider(height: 20),
                const _Label(icon: Icons.repeat_rounded, text: 'Повторяющееся событие'),
              ],
            ]),
          ),
        if (isEvent)
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: _start == null
                ? const SizedBox(width: double.infinity)
                : EnterAnimation(
                    index: 1,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _Section(children: [
                        const _Label(icon: Icons.notifications_active_rounded, text: 'Напоминание'),
                        const SizedBox(height: 10),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            for (final e in reminderOptions.entries)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _Chip(
                                  text: e.value.replaceFirst('Без напоминания', 'Нет').replaceFirst('За ', ''),
                                  active: _remind == e.key,
                                  onTap: () => setState(() => _remind = e.key),
                                ),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
          ),
        if (isEvent && widget.isNew)
          EnterAnimation(
            index: 2,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Section(children: [_repeatSection()]),
            ),
          ),
        const SizedBox(height: 12),
        EnterAnimation(
          index: 3,
          child: TextField(
            controller: _body,
            minLines: _kind == ItemKind.note ? 12 : 4,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontFamily: kFont, fontSize: 15, height: 1.4),
            decoration: InputDecoration(
              hintText: _kind == ItemKind.note ? 'Текст заметки' : 'Описание',
              contentPadding: const EdgeInsets.all(16),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: P.mantle, borderRadius: BorderRadius.circular(kRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _Label extends StatelessWidget {
  const _Label({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, color: P.subtext0, size: 22),
        const SizedBox(width: 14),
        Text(text, style: const TextStyle(fontSize: 15)),
      ]);
}

class _Tap extends StatelessWidget {
  const _Tap({required this.icon, required this.text, required this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Row(children: [
          Icon(icon, color: P.subtext0, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          const Icon(Icons.chevron_right_rounded, color: P.subtext1),
        ]),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.active, required this.onTap});
  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active ? P.accent : P.surface0,
            borderRadius: BorderRadius.circular(12),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            style: TextStyle(
              fontFamily: kFont,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: active ? P.base : P.text,
            ),
            child: Text(text),
          ),
        ),
      );
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: onTap == null ? 0.35 : 1,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: P.surface0, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: P.accent),
          ),
        ),
      );
}
