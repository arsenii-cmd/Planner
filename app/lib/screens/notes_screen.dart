import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db.dart';
import '../models.dart';
import '../theme.dart';
import 'edit_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Item>? _notes;

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
    final notes = _notes;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: OpenContainer(
        transitionDuration: const Duration(milliseconds: 420),
        openColor: P.base,
        closedColor: P.accent,
        middleColor: P.mantle,
        closedElevation: 2,
        closedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        closedBuilder: (context, open) => SizedBox(
          width: 56,
          height: 56,
          child: InkWell(onTap: open, child: const Icon(Icons.add_rounded, size: 30, color: P.base)),
        ),
        openBuilder: (context, _) => EditScreen(item: Item(kind: ItemKind.note), isNew: true),
      ),
      body: notes == null
          ? const SizedBox.shrink()
          : notes.isEmpty
              ? const EnterAnimation(child: _EmptyNotes())
              : _NotesGrid(notes: notes),
    );
  }
}

/// Two-column staggered layout: each note goes into the currently shorter column.
class _NotesGrid extends StatelessWidget {
  const _NotesGrid({required this.notes});
  final List<Item> notes;

  @override
  Widget build(BuildContext context) {
    final columns = [<Widget>[], <Widget>[]];
    final heights = [0.0, 0.0];
    for (var i = 0; i < notes.length; i++) {
      final n = notes[i];
      // Rough height estimate is enough to keep the columns balanced.
      final h = 70.0 + (n.body.length.clamp(0, 220) / 2.2) + (n.title.isEmpty ? 0 : 22);
      final c = heights[0] <= heights[1] ? 0 : 1;
      heights[c] += h;
      columns[c].add(EnterAnimation(key: ValueKey(n.id), index: i, child: _NoteCard(note: n)));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(children: columns[0])),
        const SizedBox(width: 10),
        Expanded(child: Column(children: columns[1])),
      ]),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});
  final Item note;

  @override
  Widget build(BuildContext context) {
    final fromLaptop = note.device == 'laptop';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OpenContainer(
        transitionDuration: const Duration(milliseconds: 420),
        closedColor: P.mantle,
        openColor: P.base,
        middleColor: P.mantle,
        closedElevation: 0,
        closedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
        closedBuilder: (context, open) => InkWell(
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (note.title.isNotEmpty)
                Text(note.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25)),
              if (note.body.isNotEmpty) ...[
                if (note.title.isNotEmpty) const SizedBox(height: 6),
                Text(
                  note.body,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: P.subtext0, fontSize: 13, height: 1.35),
                ),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Icon(fromLaptop ? Icons.laptop_rounded : Icons.smartphone_rounded, size: 13, color: P.subtext1),
                const SizedBox(width: 5),
                Text(
                  DateFormat('d MMM, HH:mm', 'ru_RU').format(DateTime.fromMillisecondsSinceEpoch(note.updatedAt)),
                  style: const TextStyle(fontSize: 11, color: P.subtext1),
                ),
              ]),
            ]),
          ),
        ),
        openBuilder: (context, _) => EditScreen(item: note),
      ),
    );
  }
}

class _EmptyNotes extends StatelessWidget {
  const _EmptyNotes();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.edit_note_rounded, size: 56, color: P.surface2),
        SizedBox(height: 10),
        Text('Заметок пока нет', style: TextStyle(color: P.subtext1, fontSize: 16)),
        SizedBox(height: 2),
        Text('Они появятся и на ноуте', style: TextStyle(color: P.subtext1, fontSize: 12)),
      ]),
    );
  }
}
