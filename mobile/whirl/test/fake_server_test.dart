import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

/// The fake server the sync and app tests run against must answer exactly like the real one.
/// test/server_recording.json holds what server/index.js answered (on Postgres) to a scripted
/// sequence of requests: creates, replays, late and early edits, category links, refusals,
/// deletes and creates sent after a delete. Re-record with tool/record_server.mjs.
void main() {
  const missing = '99999999-9999-4999-8999-999999999999';
  final steps = (jsonDecode(File('test/server_recording.json').readAsStringSync()) as Map)['steps'] as List;
  final iso = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$');

  test('every request is answered like the real server', () {
    var t = DateTime.utc(2026, 11, 17, 9).millisecondsSinceEpoch;
    final server = FakeWhirl(now: () => t += 1);
    final catIds = <String, String>{};
    final catNames = <String, String>{};

    Object? resolve(Object? v) {
      if (v is String) {
        return v.replaceAllMapped(RegExp(r'\{cat:([^}]+)\}'), (m) => catIds[m[1]] ?? missing);
      }
      if (v is List) return [for (final x in v) resolve(x)];
      if (v is Map) {
        if (v.containsKey(r'$ago')) return t - (v[r'$ago'] as int);
        if (v.containsKey(r'$ahead')) return t + (v[r'$ahead'] as int);
        return {for (final e in v.entries) e.key: resolve(e.value)};
      }
      return v;
    }

    Object? normalize(Object? v, [String? key]) {
      if (key == 'serverTime' && v is num) return '<now>';
      if (v is String) return iso.hasMatch(v) ? '<time>' : (catNames[v] ?? v);
      if (v is List) {
        final list = [for (final x in v) normalize(x)];
        if (key == 'categoryIds') list.sort((a, b) => '$a'.compareTo('$b'));
        return list;
      }
      if (v is Map) {
        final keys = v.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: normalize(v[k], k)};
      }
      return v;
    }

    for (final (i, step) in steps.indexed) {
      final req = step['request'] as Map;
      final want = step['response'] as Map;
      final (status, body) = server.handle(
        req['method'] as String,
        resolve(req['path']) as String,
        resolve(req['body']),
      );
      if (req['method'] == 'POST' && req['path'] == '/api/categories' && status == 201) {
        final row = body as Map;
        catIds[row['name'] as String] = row['id'] as String;
        catNames[row['id'] as String] = '{cat:${row['name']}}';
      }
      final what = 'step $i: ${req['method']} ${req['path']} ${jsonEncode(req['body'])}';
      expect(status, want['status'], reason: what);
      expect(jsonEncode(normalize(body)), jsonEncode(want['body']), reason: what);
    }
  });
}
