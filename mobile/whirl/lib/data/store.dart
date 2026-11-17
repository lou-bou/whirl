import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'model.dart';

export 'model.dart';

/// Overridden at startup.
final localDbProvider = Provider<LocalDb>((_) => throw UnimplementedError('localDbProvider'));
final initialDataProvider = Provider<WhirlData>((_) => throw UnimplementedError('initialDataProvider'));

/// The time, as epoch ms. Tests and the screenshot tool pin it.
final wallClockProvider = Provider<int Function()>(
  (_) =>
      () => DateTime.now().millisecondsSinceEpoch,
);

/// One change waiting in the device queue (src/offline.js `enqueue`): a request to replay.
class QueuedOp {
  const QueuedOp({required this.seq, required this.method, required this.path, this.body, required this.label});

  /// Its place in the queue: sent oldest first.
  final int seq;
  final String method;

  /// Below /api, e.g. `/projects/<id>`.
  final String path;
  final Json? body;

  /// The project's name, for "Couldn't save …".
  final String label;

  Json toJson() => {'method': method, 'path': path, 'body': body, 'label': label};

  static QueuedOp fromJson(int seq, Json j) => QueuedOp(
    seq: seq,
    method: j['method'] as String,
    path: j['path'] as String,
    body: j['body'] == null ? null : Map<String, Object?>.from(j['body'] as Map),
    label: j['label'] as String? ?? '',
  );

  /// The project it is about.
  String get projectId => method == 'POST' ? body!['id'] as String : path.split('/')[2];
}

/// A project change laid over a row: its fields, and its category changes. A phone sends the
/// categories added and removed; a whole `categoryIds` set (what old servers understand, and
/// what the web app sends) only counts when there are none.
Json applyChange(Json row, Json body) {
  final out = <String, Object?>{...row};
  for (final k in projectFields) {
    if (body.containsKey(k)) out[k] = body[k];
  }
  final add = body['addCategoryIds'] as List?;
  final remove = body['removeCategoryIds'] as List?;
  if (add != null || remove != null) {
    final ids = [for (final c in row['categoryIds'] as List? ?? const []) c as String];
    for (final c in remove ?? const []) {
      ids.remove(c);
    }
    for (final c in add ?? const []) {
      if (!ids.contains(c)) ids.add(c as String);
    }
    out['categoryIds'] = ids;
  } else if (body['categoryIds'] != null) {
    out['categoryIds'] = [...body['categoryIds'] as List];
  }
  return out;
}

/// A new project's row as the queue knows it.
Json createdRow(Json body) => {
  'categoryIds': const <String>[],
  for (final e in body.entries)
    if (e.key != 'editedAt') e.key: e.value,
};

/// The server's last answer with queued changes laid on top, so edits show up straight away
/// (src/offline.js `withQueuedChanges`). A queued create whose project the server already has
/// (its answer was lost) replaces it rather than showing twice.
List<Project> withQueuedChanges(Iterable<Json> server, List<QueuedOp> queue) {
  var rows = [...server];
  for (final op in queue) {
    final id = op.projectId;
    switch (op.method) {
      case 'POST':
        rows = [
          for (final r in rows)
            if (r['id'] != id) r,
          {...createdRow(op.body!), 'pending': true},
        ];
      case 'PATCH':
        rows = [
          for (final r in rows) r['id'] == id ? {...applyChange(r, op.body ?? const {}), 'pending': true} : r,
        ];
      case 'DELETE':
        rows = [
          for (final r in rows)
            if (r['id'] != id) r,
        ];
    }
  }
  final projects = [for (final r in rows) Project(r)];
  projects.sort((a, b) => byName(a.name, b.name));
  return projects;
}

/// Everything the phone holds, as one immutable snapshot the UI reads.
class WhirlData {
  WhirlData({
    this.serverProjects = const {},
    this.serverCategories = const [],
    this.queue = const [],
    this.loaded = false,
    this.serverOffset = 0,
  });

  /// The server's last answer, by id.
  final Map<String, Json> serverProjects;
  final List<Json> serverCategories;

  /// Changes waiting for the server, oldest first.
  final List<QueuedOp> queue;

  /// False until the server has answered once, so screens don't claim "nothing here" too early.
  final bool loaded;

  /// The server's clock minus this phone's, in ms, learned from `serverTime`.
  final int serverOffset;

  late final List<Project> projects = withQueuedChanges(serverProjects.values, queue);
  late final Map<String, Project> byId = {for (final p in projects) p.id: p};
  late final List<Category> categories = [for (final c in serverCategories) Category(c)]
    ..sort((a, b) => byName(a.name, b.name));

  WhirlData copyWith({
    Map<String, Json>? serverProjects,
    List<Json>? serverCategories,
    List<QueuedOp>? queue,
    bool? loaded,
    int? serverOffset,
  }) => WhirlData(
    serverProjects: serverProjects ?? this.serverProjects,
    serverCategories: serverCategories ?? this.serverCategories,
    queue: queue ?? this.queue,
    loaded: loaded ?? this.loaded,
    serverOffset: serverOffset ?? this.serverOffset,
  );
}

/// Loads the working copy from disk: everything the first frame needs.
Future<WhirlData> loadInitial(LocalDb db) async {
  final all = await db.loadAll();
  return WhirlData(
    serverProjects: {for (final p in all.projects) p['id'] as String: p},
    serverCategories: all.categories,
    queue: [for (final (seq, j) in all.queue) QueuedOp.fromJson(seq, j)],
    loaded: all.kv['loaded'] == 'yes',
    serverOffset: int.tryParse(all.kv['serverOffset'] ?? '') ?? 0,
  );
}

String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Text fields where empty and missing mean the same.
const _optionalText = {'description', 'link', 'notes'};

Object? _norm(String k, Object? v) => _optionalText.contains(k) && (v == null || v == '') ? null : v;

/// The phone's working copy and every write.
///
/// Every edit changes the in-memory [WhirlData] at once (the UI never waits), then saves the
/// queued change to SQLite. Writes are serialized, so the disk follows memory in order.
class WhirlStore extends Notifier<WhirlData> {
  late LocalDb _db;
  late int Function() _now;
  Future<void> _chain = Future.value();
  final _localChanges = StreamController<void>.broadcast();

  /// Fires after every local change (a sync is then scheduled).
  Stream<void> get localChanges => _localChanges.stream;

  @override
  WhirlData build() {
    _db = ref.watch(localDbProvider);
    _now = ref.watch(wallClockProvider);
    ref.onDispose(_localChanges.close);
    return ref.watch(initialDataProvider);
  }

  /// Wait until every queued write is on disk.
  Future<void> get flushed => _chain;

  Future<void> _persist(Future<void> Function(Transaction tx) fn) {
    final next = _chain.catchError((_) {}).then((_) => _db.db.transaction(fn));
    _chain = next;
    return next;
  }

  /// Now, on the server's clock: when an edit is made, for the server to order it.
  int serverNow() => _now() + state.serverOffset;

  int get _nextSeq => state.queue.isEmpty ? 1 : state.queue.last.seq + 1;

  void _enqueue(String method, String path, Json? body, String label) {
    final op = QueuedOp(seq: _nextSeq, method: method, path: path, body: body, label: label);
    state = state.copyWith(queue: [...state.queue, op]);
    _persist((tx) => tx.putQueued(op.seq, op.toJson()));
    if (!_localChanges.isClosed) _localChanges.add(null);
  }

  // ---------- actions (src/App.jsx saveIdea, deleteIdea, moveIdea) ----------

  /// A new project with an id picked here, so sending it twice can't make two.
  String createProject(Json fields, List<String> categoryIds) {
    final id = newUuid();
    final body = <String, Object?>{
      for (final k in projectFields)
        if (fields.containsKey(k)) k: _norm(k, fields[k]),
      'id': id,
      'categoryIds': [...categoryIds],
      'editedAt': serverNow(),
    };
    _enqueue('POST', '/projects', body, fields['name'] as String? ?? '');
    return id;
  }

  /// Only the fields that changed, so a late replay can't undo newer edits to other fields.
  /// Returns false when nothing changed.
  bool updateProject(Project before, Json fields, List<String> categoryIds) {
    final changes = <String, Object?>{};
    for (final k in projectFields) {
      if (!fields.containsKey(k)) continue;
      final v = _norm(k, fields[k]);
      if (v != _norm(k, before.row[k])) changes[k] = v;
    }
    final had = before.categoryIds;
    final add = [
      for (final c in categoryIds)
        if (!had.contains(c)) c,
    ];
    final remove = [
      for (final c in had)
        if (!categoryIds.contains(c)) c,
    ];
    if (add.isNotEmpty || remove.isNotEmpty) {
      changes['addCategoryIds'] = add;
      changes['removeCategoryIds'] = remove;
      changes['categoryIds'] = [...categoryIds];
    }
    if (changes.isEmpty) return false;
    changes['editedAt'] = serverNow();
    _enqueue('PATCH', '/projects/${before.id}', changes, (fields['name'] as String?) ?? before.name);
    return true;
  }

  void moveProject(Project p, String status) {
    if (p.status == status) return;
    _enqueue('PATCH', '/projects/${p.id}', {'status': status, 'editedAt': serverNow()}, p.name);
  }

  void deleteProject(Project p) => _enqueue('DELETE', '/projects/${p.id}', null, p.name);

  // ---------- sync (src/offline.js runFlush and fetchData) ----------

  /// The server accepted [op]: it leaves the queue, and the server copy takes it in until the
  /// next refresh brings the server's own version. [answer] is a created project's row.
  Future<void> confirmed(QueuedOp op, Object? answer) {
    final server = Map.of(state.serverProjects);
    final id = op.projectId;
    switch (op.method) {
      case 'POST':
        final row = answer is Map && answer['name'] != null
            ? Map<String, Object?>.from(answer)
            : (server[id] ?? createdRow(op.body!));
        server[id] = row;
      case 'PATCH':
        if (server[id] != null) server[id] = applyChange(server[id]!, op.body ?? const {});
      case 'DELETE':
        server.remove(id);
    }
    state = state.copyWith(
      serverProjects: server,
      queue: [
        for (final o in state.queue)
          if (o.seq != op.seq) o,
      ],
    );
    final row = server[id];
    return _persist((tx) async {
      await tx.deleteQueued(op.seq);
      if (row == null) {
        await tx.deleteProject(id);
      } else {
        await tx.putProject(row);
      }
    });
  }

  /// The server refused [op] for good: it leaves the queue and is not retried.
  Future<void> refused(QueuedOp op) {
    state = state.copyWith(
      queue: [
        for (final o in state.queue)
          if (o.seq != op.seq) o,
      ],
    );
    return _persist((tx) => tx.deleteQueued(op.seq));
  }

  /// The server's whole answer to GET /api/data, saved in one transaction. [sentAt] and
  /// [receivedAt] (this phone's clock) date the request, to learn the server's clock offset.
  Future<void> applyServerData(Json data, {required int sentAt, required int receivedAt}) {
    final projects = <String, Json>{
      for (final p in data['projects'] as List) (p as Map)['id'] as String: Map<String, Object?>.from(p),
    };
    final categories = [for (final c in data['categories'] as List) Map<String, Object?>.from(c as Map)];
    final serverTime = (data['serverTime'] as num?)?.toInt();
    final offset = serverTime == null ? state.serverOffset : serverTime - (sentAt + receivedAt) ~/ 2;
    state = state.copyWith(serverProjects: projects, serverCategories: categories, loaded: true, serverOffset: offset);
    return _persist((tx) async {
      await tx.delete('projects');
      await tx.delete('categories');
      final b = tx.batch();
      for (final p in projects.values) {
        b.insert('projects', {'id': p['id'], 'data': jsonEncode(p)});
      }
      for (final c in categories) {
        b.insert('categories', {'id': c['id'], 'data': jsonEncode(c)});
      }
      await b.commit(noResult: true);
      await tx.putKv('loaded', 'yes');
      await tx.putKv('serverOffset', '$offset');
    });
  }

  /// A different server: nothing from the old one may stay.
  Future<void> reset() {
    state = WhirlData();
    return _persist((tx) async {
      await tx.delete('projects');
      await tx.delete('categories');
      await tx.delete('queue');
      await tx.delete('kv');
    });
  }
}

final storeProvider = NotifierProvider<WhirlStore, WhirlData>(WhirlStore.new);
