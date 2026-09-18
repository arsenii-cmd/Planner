import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../models.dart';
import 'edit_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Item> _notes = [];

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
    final notes = await LocalDb.instance.notes();
    if (mounted) setState(() => _notes = notes);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('d MMM, HH:mm', 'ru_RU');
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: () => openEditor(context, Item(kind: ItemKind.note)),
        child: const Icon(Icons.add),
      ),
      body: _notes.isEmpty
          ? Center(
              child: Text('Заметок пока нет',
                  style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.5))),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              itemCount: _notes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final n = _notes[i];
                return Card(
                  color: scheme.surfaceContainerHigh,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => openEditor(context, n),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (n.title.isNotEmpty)
                          Text(n.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        if (n.body.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(n.body, maxLines: 4, overflow: TextOverflow.ellipsis),
                          ),
                        const SizedBox(height: 6),
                        Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(n.updatedAt)),
                            style: TextStyle(fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.5))),
                      ]),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
