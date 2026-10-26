import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/scan_entry.dart';

/// Persistence for scan history entries.
abstract class ScanRepository {
  Future<List<ScanEntry>> all();
  Future<ScanEntry> insert(ScanEntry entry);
  Future<void> rename(int id, String title);
  Future<void> delete(int id);
}

/// SQLite-backed repository, the default used by the app.
class SqfliteScanRepository implements ScanRepository {
  SqfliteScanRepository({this.databasePath});

  /// Optional explicit database file path (tests / custom storage).
  final String? databasePath;

  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        databasePath ?? p.join(await getDatabasesPath(), 'scan.db');
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE scans (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            file_path TEXT NOT NULL,
            thumb_path TEXT,
            shared_uri TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE scans ADD COLUMN shared_uri TEXT');
        }
        if (oldVersion < 3) {
          // Dismissing an imported file is a transient thing, not state worth a
          // table; the table that remembered it goes away again.
          await db.execute('DROP TABLE IF EXISTS hidden_media');
        }
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<List<ScanEntry>> all() async {
    final db = await _open();
    final rows = await db.query('scans', orderBy: 'created_at DESC');
    return rows.map(ScanEntry.fromMap).toList();
  }

  @override
  Future<ScanEntry> insert(ScanEntry entry) async {
    final db = await _open();
    final values = entry.toMap()..remove('id');
    final id = await db.insert('scans', values);
    return entry.copyWith(id: id);
  }

  @override
  Future<void> rename(int id, String title) async {
    final db = await _open();
    await db.update(
      'scans',
      <String, Object>{'title': title},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
  }

  @override
  Future<void> delete(int id) async {
    final db = await _open();
    await db.delete('scans', where: 'id = ?', whereArgs: <Object>[id]);
  }
}

/// In-memory repository used by widget and unit tests.
class InMemoryScanRepository implements ScanRepository {
  InMemoryScanRepository({Iterable<ScanEntry>? seed}) {
    for (final entry in seed ?? const <ScanEntry>[]) {
      _rows.add(entry.copyWith(id: _nextId++));
    }
  }

  final List<ScanEntry> _rows = <ScanEntry>[];
  int _nextId = 1;

  @override
  Future<List<ScanEntry>> all() async {
    final sorted = List<ScanEntry>.from(_rows)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  @override
  Future<ScanEntry> insert(ScanEntry entry) async {
    final saved = entry.copyWith(id: _nextId++);
    _rows.insert(0, saved);
    return saved;
  }

  @override
  Future<void> rename(int id, String title) async {
    final index = _rows.indexWhere((entry) => entry.id == id);
    if (index >= 0) _rows[index] = _rows[index].copyWith(title: title);
  }

  @override
  Future<void> delete(int id) async {
    _rows.removeWhere((entry) => entry.id == id);
  }
}
