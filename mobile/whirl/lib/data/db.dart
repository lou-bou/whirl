import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'model.dart';

/// The phone's working copy in SQLite: the server's last answer (projects and categories), the
/// device queue of changes waiting for the server, in order, and small key/values.
class LocalDb {
  LocalDb(this.db);
  final Database db;

  static const version = 1;

  static Future<LocalDb> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, _) async {
          final b = db.batch();
          b.execute('CREATE TABLE projects (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
          b.execute('CREATE TABLE categories (id TEXT PRIMARY KEY, data TEXT NOT NULL)');
          b.execute('CREATE TABLE queue (seq INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL)');
          b.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await b.commit(noResult: true);
        },
      ),
    );
    return LocalDb(db);
  }

  Future<void> close() => db.close();

  /// Everything, for the first frame.
  Future<({List<Json> projects, List<Json> categories, List<(int, Json)> queue, Map<String, String> kv})>
  loadAll() async {
    Json decode(Object? s) => Map<String, Object?>.from(jsonDecode(s as String) as Map);
    return (
      projects: [for (final r in await db.query('projects')) decode(r['data'])],
      categories: [for (final r in await db.query('categories')) decode(r['data'])],
      queue: [for (final r in await db.query('queue', orderBy: 'seq')) (r['seq'] as int, decode(r['data']))],
      kv: {for (final r in await db.query('kv')) r['key'] as String: r['value'] as String},
    );
  }
}

/// Writes inside one transaction.
extension Writes on DatabaseExecutor {
  Future<void> putProject(Json row) => insert('projects', {
    'id': row['id'],
    'data': jsonEncode(row),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteProject(String id) => delete('projects', where: 'id = ?', whereArgs: [id]);

  Future<void> putCategory(Json row) => insert('categories', {
    'id': row['id'],
    'data': jsonEncode(row),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> putQueued(int seq, Json op) =>
      insert('queue', {'seq': seq, 'data': jsonEncode(op)}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteQueued(int seq) => delete('queue', where: 'seq = ?', whereArgs: [seq]);

  Future<void> putKv(String key, String value) =>
      insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
}
