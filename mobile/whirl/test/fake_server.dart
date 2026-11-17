import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:kit/kit.dart';
import 'package:kit/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:whirl/data/db.dart';
import 'package:whirl/data/store.dart';
import 'package:whirl/ui/state.dart';

const testConnection = ServerConnection(baseUrl: 'https://wheel.test', clientId: 'id.access', clientSecret: 'secret');

/// A Postgres error the server turns into an answer (server/index.js REJECTED).
class _Pg implements Exception {
  const _Pg(this.code);
  final String code;
}

const _rejected = {
  '23505': (409, 'that name is already taken'),
  '23503': (409, 'a category it uses no longer exists'),
  '23502': (400, 'a required field is missing'),
  '23514': (400, 'a field has an invalid value'),
  '22P02': (400, 'a field has an invalid value'),
};

final _uuid = RegExp(r'^\{?[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\}?$', caseSensitive: false);

String _uuidArg(Object? v) {
  if (v is! String || !_uuid.hasMatch(v)) throw const _Pg('22P02');
  return v
      .toLowerCase()
      .replaceAll(RegExp(r'[{}-]'), '')
      .replaceAllMapped(RegExp(r'^(.{8})(.{4})(.{4})(.{4})(.{12})$'), (m) => '${m[1]}-${m[2]}-${m[3]}-${m[4]}-${m[5]}');
}

/// How `pg` sends a JS value as a text parameter.
String? _text(Object? v) => v == null ? null : (v is String ? v : '$v');

const _checks = {
  'difficulty': ['Easy', 'Medium', 'Hard', 'Expert'],
  'dev_type': ['Manual', 'Assisted'],
  'status': ['idea', 'doing', 'completed'],
};

/// Postgres boolean input.
bool? _bool(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  final s = (_text(v) ?? '').trim().toLowerCase();
  if (s.isEmpty) throw const _Pg('22P02');
  for (final (word, value) in [('true', true), ('false', false), ('yes', true), ('no', false)]) {
    if (word.startsWith(s)) return value;
  }
  if (s == 'on' || s == '1') return true;
  if (s == 'of' || s == 'off' || s == '0') return false;
  throw const _Pg('22P02');
}

/// JavaScript's Number(), for edit times.
double? _jsNumber(Object? v) {
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  if (v is String) return v.trim().isEmpty ? 0 : double.tryParse(v.trim());
  if (v is List && v.isEmpty) return 0;
  return null;
}

/// server/index.js and its Postgres tables in Dart, for tests. It must answer every request like
/// the real one: test/server_recording.json holds what the real server answered to a scripted
/// sequence, and fake_server_test.dart replays it here.
class FakeWhirl {
  FakeWhirl({int Function()? now}) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  int Function() now;
  final projects = <String, Json>{};
  final categories = <String, Json>{};

  /// project id → category ids, in the order they were linked.
  final links = <String, List<String>>{};
  final deleted = <String>{};

  static const projectFields = [
    'name',
    'description',
    'difficulty',
    'dev_type',
    'status',
    'link',
    'has_content',
    'notes',
  ];

  // ---------- what the network does ----------

  bool offline = false;
  bool accessDenied = false;
  bool serverDown = false;

  /// The next change never reaches the server.
  bool dropNextChange = false;

  /// The next change is applied, but its answer never comes back.
  bool loseNextChange = false;

  /// Called with each change before it is applied (to kill the app mid-send).
  void Function(String method, String path)? beforeChange;
  int changes = 0;
  int reads = 0;

  late final adapter = FakeAdapter((r, body) {
    if (offline) throw const FakeOffline();
    if (accessDenied) return const FakeResponse(302, '', {'location': 'https://x.cloudflareaccess.com/login'});
    if (serverDown) return const FakeResponse(502, '<html>Bad gateway</html>');
    final isChange = r.method != 'GET';
    if (isChange && dropNextChange) {
      dropNextChange = false;
      throw const FakeOffline();
    }
    if (isChange) {
      beforeChange?.call(r.method, r.uri.path);
      changes++;
    } else {
      reads++;
    }
    final (status, answer) = handle(r.method, r.uri.path, body);
    if (isChange && loseNextChange) {
      loseNextChange = false;
      throw const FakeLostResponse();
    }
    return FakeResponse(status, answer);
  });

  Dio dio() => fakeDio(adapter);

  // ---------- the API ----------

  String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  String _uuidNew() {
    final r = Random();
    String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
  }

  (int, Object?) handle(String method, String path, Object? rawBody) {
    final body = rawBody is Map ? Map<String, Object?>.from(rawBody) : <String, Object?>{};
    final parts = path.split('/');
    try {
      if (path == '/api/data' && method == 'GET') return (200, data());
      if (parts.length == 3 && parts[2] == 'projects' && method == 'POST') return _createProject(body);
      if (parts.length == 4 && parts[2] == 'projects' && method == 'PATCH') return _patchProject(parts[3], body);
      if (parts.length == 4 && parts[2] == 'projects' && method == 'DELETE') return _deleteProject(parts[3]);
      if (parts.length == 3 && parts[2] == 'categories' && method == 'POST') return _createCategory(body);
      if (parts.length == 4 && parts[2] == 'categories' && method == 'PATCH') return _renameCategory(parts[3], body);
      if (parts.length == 4 && parts[2] == 'categories' && method == 'DELETE') return _deleteCategory(parts[3]);
      return (404, {'error': 'not found'});
    } on _Pg catch (e) {
      final (status, message) = _rejected[e.code]!;
      return (status, {'error': message});
    }
  }

  Json _out(Json row) => {
    for (final e in row.entries)
      if (e.key != 'field_times') e.key: e.value,
    'categoryIds': [...?links[row['id']]],
  };

  Json data() {
    int byText(String a, String b) => a.compareTo(b);
    final p = projects.values.toList()..sort((a, b) => byText(a['name'] as String, b['name'] as String));
    final c = categories.values.toList()..sort((a, b) => byText(a['name'] as String, b['name'] as String));
    return {
      'projects': [for (final r in p) _out(r)],
      'categories': [for (final r in c) Map.of(r)],
      'serverTime': now(),
    };
  }

  int _editTime(Json body, int now) {
    final v = body['editedAt'];
    if (v == null) return now;
    final t = _jsNumber(v);
    if (t == null || t.isNaN || t.isInfinite) throw const _Pg('22P02');
    return min(t, now.toDouble()).round();
  }

  List<Object?> _idList(Object? v) {
    if (v == null) return const [];
    if (v is! List) throw const _Pg('22P02');
    final seen = <Object?>[];
    for (final x in v) {
      if (!seen.contains(x)) seen.add(x);
    }
    return seen;
  }

  List<String> _known(List<Object?> ids) {
    if (ids.isEmpty) return const [];
    final parsed = [for (final id in ids) _uuidArg(id)];
    return [
      for (final (i, id) in parsed.indexed)
        if (categories.containsKey(id) && ids[i] == id) id,
    ];
  }

  bool _newer(Json times, String key, int at) {
    final t = times[key];
    return !(t is num && t > at);
  }

  /// A column's value as Postgres would store it, or the error it would raise. Type errors come
  /// first (when the parameters are read), then NOT NULL, then CHECK.
  Json _columns(List<(String, Object?)> fields, {bool insert = false}) {
    final out = <String, Object?>{};
    for (final (k, v) in fields) {
      out[k] = k == 'has_content' ? _bool(v) : _text(v);
    }
    for (final k in const ['name', 'difficulty', 'dev_type', 'status', 'has_content']) {
      if (out.containsKey(k) && out[k] == null) throw const _Pg('23502');
    }
    if (insert && !out.containsKey('name')) throw const _Pg('23502');
    for (final e in _checks.entries) {
      if (out.containsKey(e.key) && !e.value.contains(out[e.key])) throw const _Pg('23514');
    }
    return out;
  }

  List<(String, Object?)> _pick(Json body, List<String> allowed) => [
    for (final k in allowed)
      if (body.containsKey(k)) (k, body[k]),
  ];

  (int, Object?) _createProject(Json body) {
    final t = now();
    final at = _editTime(body, t);
    final rawId = body['id'];
    String? id;
    if (rawId != null && rawId != '' && rawId != false && rawId != 0) {
      id = _uuidArg(rawId);
      if (deleted.contains(id)) return (410, {'error': 'this project was deleted on another device'});
    }
    final known = _known(_idList(body['categoryIds']));
    final fields = _pick(body, ['id', ...projectFields]);
    if (fields.any((f) => f.$1 == 'id')) _uuidArg(fields.firstWhere((f) => f.$1 == 'id').$2);
    final values = _columns([
      for (final f in fields)
        if (f.$1 != 'id') f,
    ], insert: true);
    final key = id ?? _uuidNew();
    if (projects.containsKey(key)) return (200, {'id': rawId});
    final row = <String, Object?>{
      'id': key,
      'name': values['name'],
      'description': values['description'],
      'difficulty': values['difficulty'] ?? 'Medium',
      'dev_type': values['dev_type'] ?? 'Assisted',
      'status': values['status'] ?? 'idea',
      'link': values['link'],
      'has_content': values['has_content'] ?? false,
      'notes': values['notes'],
      'created_at': _iso(t),
      'updated_at': _iso(t),
      'field_times': {for (final k in projectFields) k: at, for (final c in known) 'cat:$c': at},
    };
    projects[key] = row;
    links[key] = [...known];
    return (
      201,
      {
        ..._out(row),
        'categoryIds': [...known],
      },
    );
  }

  (int, Object?) _patchProject(String rawId, Json body) {
    final t = now();
    final at = _editTime(body, t);
    final id = _uuidArg(rawId);
    final row = projects[id];
    if (row == null) {
      return deleted.contains(id)
          ? (410, {'error': 'this project was deleted on another device'})
          : (404, {'error': 'this project no longer exists'});
    }
    final times = Map<String, Object?>.from(row['field_times'] as Map);
    final fields = [
      for (final f in _pick(body, projectFields))
        if (_newer(times, f.$1, at)) f,
    ];
    var add = <Object?>[];
    var remove = <Object?>[];
    if (body.containsKey('addCategoryIds') || body.containsKey('removeCategoryIds')) {
      add = _idList(body['addCategoryIds']);
      remove = _idList(body['removeCategoryIds']);
    } else if (body.containsKey('categoryIds')) {
      final wanted = _idList(body['categoryIds']);
      final current = links[id] ?? const [];
      add = [
        for (final w in wanted)
          if (!current.contains(w)) w,
      ];
      remove = [
        for (final c in current)
          if (!wanted.contains(c)) c,
      ];
    }
    final added = [
      for (final c in _known(add))
        if (_newer(times, 'cat:$c', at)) c,
    ];
    final removed = [
      for (final c in remove)
        if (_newer(times, 'cat:$c', at)) c,
    ];
    if (fields.isEmpty && added.isEmpty && removed.isEmpty) return (204, null);

    final values = _columns(fields);
    final removeIds = [for (final c in removed) _uuidArg(c)];
    final next = {...row, ...values, 'updated_at': _iso(t)};
    for (final (k, _) in fields) {
      times[k] = at;
    }
    for (final c in [...added, ...removed]) {
      times['cat:$c'] = at;
    }
    next['field_times'] = times;
    projects[id] = next;
    final list = [...?links[id]];
    for (final c in added) {
      if (!list.contains(c)) list.add(c);
    }
    list.removeWhere(removeIds.contains);
    links[id] = list;
    return (204, null);
  }

  (int, Object?) _deleteProject(String rawId) {
    final id = _uuidArg(rawId);
    projects.remove(id);
    links.remove(id);
    deleted.add(id);
    return (204, null);
  }

  (int, Object?) _createCategory(Json body) {
    final name = _text(body['name']);
    if (name == null) throw const _Pg('23502');
    if (categories.values.any((c) => c['name'] == name)) throw const _Pg('23505');
    final row = {'id': _uuidNew(), 'name': name, 'created_at': _iso(now())};
    categories[row['id']!] = row;
    return (201, row);
  }

  (int, Object?) _renameCategory(String rawId, Json body) {
    final id = _uuidArg(rawId);
    final row = categories[id];
    if (row == null) return (204, null);
    final name = _text(body['name']);
    if (name == null) throw const _Pg('23502');
    if (categories.values.any((c) => c['name'] == name && c['id'] != id)) throw const _Pg('23505');
    categories[id] = {...row, 'name': name};
    return (204, null);
  }

  (int, Object?) _deleteCategory(String rawId) {
    final id = _uuidArg(rawId);
    categories.remove(id);
    for (final l in links.values) {
      l.remove(id);
    }
    return (204, null);
  }
}

/// One simulated phone: its own database and providers.
class Client {
  Client._(this.container, this.db, this.path);
  final ProviderContainer container;
  final LocalDb db;
  final String path;

  static Future<Client> start(
    FakeWhirl server,
    Directory dir, {
    String name = 'a',
    bool connected = true,
    int Function()? clock,
    List<Override> extra = const [],
    bool splash = false,
  }) async {
    sqfliteFfiInit();
    final path = '${dir.path}/$name.db';
    final db = await LocalDb.open(path, factory: databaseFactoryFfi);
    final init = await loadInitial(db);
    final boot = KitBoot.memory(
      Directory('${dir.path}/$name-kit')..createSync(recursive: true),
      connection: connected ? testConnection : null,
    );
    final overrides = <Override>[
      ...boot.overrides,
      dioProvider.overrideWithValue(server.dio()),
      localDbProvider.overrideWithValue(db),
      initialDataProvider.overrideWithValue(init),
      networkRegainedProvider.overrideWithValue(const Stream.empty()),
      if (clock != null) wallClockProvider.overrideWithValue(clock),
      splashProvider.overrideWithValue(splash),
      ...extra,
    ];
    return Client._(ProviderContainer(overrides: overrides), db, path);
  }

  WhirlStore get store => container.read(storeProvider.notifier);
  WhirlData get data => container.read(storeProvider);

  Future<void> dispose() async {
    await store.flushed;
    container.dispose();
    await db.close();
  }
}
