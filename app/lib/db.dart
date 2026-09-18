import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Local copy of all items. Every local edit is marked dirty until the
/// laptop has accepted it, so the app works fully offline.
class LocalDb extends ChangeNotifier {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;

  Future<Database> get _database async {
    return _db ??= await openDatabase(
      p.join(await getDatabasesPath(), 'planner.db'),
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            body TEXT NOT NULL DEFAULT '',
            date TEXT,
            start_time TEXT,
            end_time TEXT,
            done INTEGER NOT NULL DEFAULT 0,
            color TEXT,
            remind INTEGER,
            series TEXT,
            updated_at INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0,
            device TEXT NOT NULL DEFAULT '',
            dirty INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('CREATE INDEX items_date ON items(date)');
      },
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute('ALTER TABLE items ADD COLUMN remind INTEGER');
        if (from < 3) await db.execute('ALTER TABLE items ADD COLUMN series TEXT');
      },
    );
  }

  Future<List<Item>> range(String from, String to) async {
    final db = await _database;
    final rows = await db.query(
      'items',
      where: 'deleted = 0 AND kind != ? AND date >= ? AND date <= ?',
      whereArgs: ['note', from, to],
      orderBy: "date, COALESCE(start_time, '99:99'), updated_at",
    );
    return rows.map(Item.fromRow).toList();
  }

  /// Timed events with a reminder in [from, to] (used to schedule notifications).
  Future<List<Item>> remindable(String from, String to) async {
    final db = await _database;
    final rows = await db.query(
      'items',
      where: "deleted = 0 AND kind = 'event' AND remind IS NOT NULL AND start_time IS NOT NULL "
          'AND date >= ? AND date <= ?',
      whereArgs: [from, to],
      orderBy: 'date, start_time',
    );
    return rows.map(Item.fromRow).toList();
  }

  Future<List<Item>> notes() async {
    final db = await _database;
    final rows = await db.query(
      'items',
      where: "deleted = 0 AND kind = 'note'",
      orderBy: 'updated_at DESC',
    );
    return rows.map(Item.fromRow).toList();
  }

  /// Local create/update/delete: bumps the timestamp and queues it for sync.
  Future<void> save(Item item) async {
    item.touch();
    final db = await _database;
    await db.insert('items', item.toRow(dirty: true),
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  /// Saves several items in one transaction (series create/edit/delete) with one notification.
  Future<void> saveAll(List<Item> items) async {
    final db = await _database;
    await db.transaction((txn) async {
      for (final it in items) {
        it.touch();
        await txn.insert('items', it.toRow(dirty: true), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    notifyListeners();
  }

  Future<Item?> get(String id) async {
    final db = await _database;
    final rows = await db.query('items', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Item.fromRow(rows.first);
  }

  /// Unfinished one-off tasks from past days move to [today] (same rule as plannerd).
  Future<int> carryOverTasks(String today) async {
    final db = await _database;
    final rows = await db.query('items',
        where: "kind = 'task' AND deleted = 0 AND done = 0 AND series IS NULL AND date < ?",
        whereArgs: [today]);
    if (rows.isEmpty) return 0;
    await saveAll([for (final r in rows) Item.fromRow(r)..date = today]);
    return rows.length;
  }

  Future<List<Item>> seriesItems(String series) async {
    final db = await _database;
    final rows = await db.query('items',
        where: 'deleted = 0 AND series = ?', whereArgs: [series], orderBy: 'date');
    return rows.map(Item.fromRow).toList();
  }

  Future<void> remove(Item item) async {
    item.deleted = true;
    await save(item);
  }

  Future<List<Item>> dirty() async {
    final db = await _database;
    final rows = await db.query('items', where: 'dirty = 1');
    return rows.map(Item.fromRow).toList();
  }

  /// Apply changes from the laptop; a newer local edit is kept.
  Future<void> applyRemote(List<Item> remote) async {
    if (remote.isEmpty) return;
    final db = await _database;
    await db.transaction((txn) async {
      for (final r in remote) {
        final cur = await txn.query('items', where: 'id = ?', whereArgs: [r.id]);
        if (cur.isNotEmpty && !r.isNewerThan(Item.fromRow(cur.first))) continue;
        await txn.insert('items', r.toRow(dirty: false),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    notifyListeners();
  }

  /// Clear the dirty flag only if the item was not edited again meanwhile.
  Future<void> markClean(List<Item> sent) async {
    final db = await _database;
    final batch = db.batch();
    for (final s in sent) {
      batch.update('items', {'dirty': 0},
          where: 'id = ? AND updated_at = ?', whereArgs: [s.id, s.updatedAt]);
    }
    await batch.commit(noResult: true);
  }
}
