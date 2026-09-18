import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../models.dart';
import '../reminders.dart';

Future<void> openEditor(BuildContext context, Item item) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditScreen(item: item)));
}

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.item});
  final Item item;

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

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty && body.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final it = widget.item
      ..title = title
      ..body = body
      ..date = _kind == ItemKind.note ? null : _date
      ..startTime = _kind == ItemKind.event ? _start : null
      ..endTime = _kind == ItemKind.event && _start != null ? _end : null
      ..remind = _kind == ItemKind.event && _start != null ? _remind : null;
    await LocalDb.instance.save(it);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
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

  @override
  Widget build(BuildContext context) {
    final dateLabel = _date == null
        ? 'Выбрать дату'
        : DateFormat('EEEE, d MMMM y', 'ru_RU').format(parseDateKey(_date!));
    return Scaffold(
      appBar: AppBar(
        title: Text(_heading),
        actions: [
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete, tooltip: 'Удалить'),
          IconButton(icon: const Icon(Icons.check), onPressed: _save, tooltip: 'Сохранить'),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _title,
          autofocus: widget.item.title.isEmpty,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(hintText: 'Название', border: InputBorder.none),
        ),
        if (_kind != ItemKind.note)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.today),
            title: Text(dateLabel),
            onTap: _pickDate,
          ),
        if (_kind == ItemKind.event)
          Row(children: [
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(_start ?? 'Весь день'),
                onTap: () async {
                  final t = await _pickTime(_start);
                  setState(() => _start = t);
                },
              ),
            ),
            if (_start != null)
              Expanded(
                child: ListTile(
                  title: Text(_end == null ? 'до …' : 'до $_end'),
                  onTap: () async {
                    final t = await _pickTime(_end ?? _start);
                    setState(() => _end = t);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Весь день',
                    onPressed: () => setState(() {
                      _start = null;
                      _end = null;
                    }),
                  ),
                ),
              ),
          ]),
        if (_kind == ItemKind.event && _start != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_remind == null ? Icons.notifications_off_outlined : Icons.notifications_active_outlined),
            title: DropdownButtonHideUnderline(
              child: DropdownButton<int?>(
                value: reminderOptions.containsKey(_remind) ? _remind : 15,
                isExpanded: true,
                items: [
                  for (final e in reminderOptions.entries)
                    DropdownMenuItem<int?>(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _remind = v),
              ),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          minLines: _kind == ItemKind.note ? 10 : 4,
          maxLines: null,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: _kind == ItemKind.note ? 'Текст заметки' : 'Описание',
            border: const OutlineInputBorder(),
          ),
        ),
      ]),
    );
  }
}
