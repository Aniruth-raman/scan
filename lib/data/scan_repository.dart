import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/scan_entry.dart';

/// Persistence for scan history entries.
abstract class ScanRepository {
  Future<List<ScanEntry>> all();
  Future<ScanEntry> insert(ScanEntry entry);
  Future<void> rename(int id, String title);
  Future<void> delete(int id);

  /// Shared files the user removed from the list. The files themselves stay:
  /// they were never ours to delete.
  Future<Set<String>> hiddenMedia();
  Future<void> hideMedia(String uri);
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
        databasePath ?? p.join(await getDatabasesPath(), 'lens_lite_scans.db');
    final db = await openDatabase(
      path,
      version: 2,
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
        await db.execute('''
          CREATE TABLE hidden_media (
            uri TEXT PRIMARY KEY,
            hidden_at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE scans ADD COLUMN shared_uri TEXT');
          await db.execute('''
            CREATE TABLE hidden_media (
              uri TEXT PRIMARY KEY,
              hidden_at INTEGER NOT NULL
            )
          ''');
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

  @override
  Future<Set<String>> hiddenMedia() async {
    final db = await _open();
    final rows = await db.query('hidden_media', columns: const ['uri']);
    return rows.map((row) => row['uri']! as String).toSet();
  }

  @override
  Future<void> hideMedia(String uri) async {
    final db = await _open();
    await db.insert('hidden_media', <String, Object>{
      'uri': uri,
      'hidden_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null) await db.close();
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
  final Set<String> _hidden = <String>{};
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

  @override
  Future<Set<String>> hiddenMedia() async => Set<String>.of(_hidden);

  @override
  Future<void> hideMedia(String uri) async => _hidden.add(uri);
}
