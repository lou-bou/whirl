import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whirl/data/store.dart';
import 'package:whirl/data/sync.dart';

import 'fake_server.dart';

/// Two phones against the fake server, which answers exactly like the real one
/// (fake_server_test.dart). Real SQLite, real store, real sync.
void main() {
  late Directory dir;
  late FakeWhirl server;
  // One clock for everyone, moving 1 ms per reading, so "later" is never a tie.
  var t = DateTime.utc(2026, 11, 17, 8).millisecondsSinceEpoch;
  int tick() => t += 1;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('whirl_sync');
    server = FakeWhirl(now: tick);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Client> phone(String name, {int Function()? clock}) =>
      Client.start(server, dir, name: name, clock: clock ?? tick);
  Future<void> sync(Client c) => c.container.read(syncProvider.notifier).sync();
  SyncState stateOf(Client c) => c.container.read(syncProvider).state;
  String? notice(Client c) => c.container.read(noticeProvider);

  Map<String, Object?> rowOf(Map r) => {
    for (final e in r.entries)
      if (e.key != 'pending') e.key as String: e.value,
    'categoryIds': [...(r['categoryIds'] as List? ?? const [])]..sort((a, b) => '$a'.compareTo('$b')),
  };

  /// Every project a phone shows, as text.
  String dump(Client c) => jsonEncode({for (final p in c.data.projects) p.id: rowOf(p.row)});
  String serverDump() => jsonEncode({
    for (final p in (server.data()['projects'] as List).cast<Map>()..sort((a, b) => byName(a['name'], b['name'])))
      p['id']: rowOf(p),
  });

  Project byTitle(Client c, String name) => c.data.projects.firstWhere((p) => p.name == name);

  Future<String> category(String name) async {
    final (_, body) = server.handle('POST', '/api/categories', {'name': name});
    return (body as Map)['id'] as String;
  }

  Map<String, Object?> form(Project p, Map<String, Object?> changes) => {...p.row, ...changes};

  test('an idea made on one phone arrives on the other, the same everywhere', () async {
    final web = await category('web');
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Portfolio', 'difficulty': 'Hard', 'description': '# Plan'}, [web]);
    expect(a.data.projects.single.pending, true, reason: 'shown at once, before the server has it');
    await sync(a);
    expect(stateOf(a), SyncState.synced);
    expect(a.data.queue, isEmpty);
    expect(b.data.loaded, false);
    await sync(b);
    expect(b.data.loaded, true);
    final p = byTitle(b, 'Portfolio');
    expect(p.difficulty, 'Hard');
    expect(p.categoryIds, [web]);
    expect(p.pending, false);
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('offline edits of different fields on two phones are both kept', () async {
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Game'}, []);
    await sync(a);
    await sync(b);

    server.offline = true;
    a.store.updateProject(byTitle(a, 'Game'), form(byTitle(a, 'Game'), {'difficulty': 'Expert'}), []);
    a.store.updateProject(byTitle(a, 'Game'), form(byTitle(a, 'Game'), {'notes': 'Use Godot'}), []);
    b.store.moveProject(byTitle(b, 'Game'), 'doing');
    await sync(a);
    await sync(b);
    expect(stateOf(a), SyncState.offline);
    expect(a.data.queue.length, 2, reason: 'one queued change per action, like the web app');
    expect(byTitle(a, 'Game').difficulty, 'Expert', reason: 'the edit shows at once, offline');

    server.offline = false;
    await sync(a);
    await sync(b);
    await sync(a);
    for (final c in [a, b]) {
      final p = byTitle(c, 'Game');
      expect(p.difficulty, 'Expert');
      expect(p.notes, 'Use Godot');
      expect(p.status, 'doing');
      expect(c.data.queue, isEmpty);
    }
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('the same field edited offline on two phones: the later edit wins, whoever sends first', () async {
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Start'}, []);
    await sync(a);
    await sync(b);

    server.offline = true;
    a.store.updateProject(byTitle(a, 'Start'), form(byTitle(a, 'Start'), {'name': 'From A, earlier'}), []);
    b.store.updateProject(byTitle(b, 'Start'), form(byTitle(b, 'Start'), {'name': 'From B, later'}), []);
    server.offline = false;
    // B's later edit arrives first, A's earlier one last: arrival order would let A win.
    await sync(b);
    await sync(a);
    await sync(b);
    expect(a.data.projects.single.name, 'From B, later');
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('a phone whose clock is an hour slow still orders its edits by the server clock', () async {
    final a = await phone('a', clock: () => tick() - const Duration(hours: 1).inMilliseconds);
    final b = await phone('b');
    b.store.createProject({'name': 'Clock'}, []);
    await sync(b);
    await sync(a); // learns how far behind it is

    server.offline = true;
    b.store.updateProject(byTitle(b, 'Clock'), form(byTitle(b, 'Clock'), {'status': 'doing'}), []);
    a.store.updateProject(byTitle(a, 'Clock'), form(byTitle(a, 'Clock'), {'status': 'completed'}), []);
    server.offline = false;
    await sync(a);
    await sync(b);
    await sync(a);
    expect(byTitle(a, 'Clock').status, 'completed', reason: "A's edit was made last");
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('categories added offline on two phones are both kept, and a late removal loses', () async {
    final games = await category('games');
    final web = await category('web');
    final tools = await category('tools');
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Mix'}, [tools]);
    await sync(a);
    await sync(b);

    server.offline = true;
    // B removes tools first; A adds games later; B then adds web.
    b.store.updateProject(byTitle(b, 'Mix'), byTitle(b, 'Mix').row, []);
    a.store.updateProject(byTitle(a, 'Mix'), byTitle(a, 'Mix').row, [tools, games]);
    b.store.updateProject(byTitle(b, 'Mix'), byTitle(b, 'Mix').row, [web]);
    expect(byTitle(b, 'Mix').categoryIds, [web]);
    server.offline = false;
    await sync(b);
    await sync(a);
    await sync(b);
    expect(byTitle(a, 'Mix').categoryIds.toSet(), {games, web});
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('a lost answer to a create: sent again, it never makes a second idea', () async {
    final a = await phone('a');
    a.store.createProject({'name': 'Once'}, []);
    server.loseNextChange = true;
    await sync(a);
    expect(stateOf(a), SyncState.offline);
    expect(a.data.queue.length, 1, reason: 'kept until the server answers for it');
    expect(server.projects.length, 1, reason: 'the server did get it');
    await sync(a);
    expect(stateOf(a), SyncState.synced);
    expect(server.projects.length, 1);
    expect(a.data.projects.length, 1);
    expect(dump(a), serverDump());
    await a.dispose();
  });

  test('a lost answer to an edit: sent again, it does not undo a newer edit from another phone', () async {
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Draft'}, []);
    await sync(a);
    await sync(b);
    a.store.updateProject(byTitle(a, 'Draft'), form(byTitle(a, 'Draft'), {'name': 'Older'}), []);
    server.loseNextChange = true;
    await sync(a);
    await sync(b);
    b.store.updateProject(byTitle(b, 'Older'), form(byTitle(b, 'Older'), {'name': 'Newer'}), []);
    await sync(b);
    await sync(a); // A sends its edit again
    expect(server.changes, 4, reason: 'create, the lost edit, B, the replay');
    await sync(b);
    expect(a.data.projects.single.name, 'Newer');
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('a request that never left is sent later', () async {
    final a = await phone('a');
    a.store.createProject({'name': 'Later'}, []);
    server.dropNextChange = true;
    await sync(a);
    expect(server.projects, isEmpty);
    expect(a.data.queue.length, 1);
    await sync(a);
    expect(server.projects.length, 1);
    expect(a.data.queue, isEmpty);
    await a.dispose();
  });

  test('the app killed mid-send: the change is still queued after a restart, and lands once', () async {
    var a = await phone('a');
    a.store.createProject({'name': 'Survivor'}, []);
    a.store.createProject({'name': 'Second'}, []);
    // The server applies the first create, then the app dies before the answer arrives.
    server.loseNextChange = true;
    await sync(a);
    expect(server.projects.length, 1);
    await a.dispose();

    a = await phone('a');
    expect(a.data.queue.length, 2, reason: 'nothing was confirmed, so both are still queued');
    expect(a.data.projects.map((p) => p.name), ['Second', 'Survivor']);
    await sync(a);
    expect(server.projects.length, 2);
    expect(a.data.queue, isEmpty);
    expect(dump(a), serverDump());
    await a.dispose();

    // Opening again offline shows the same, from SQLite alone.
    server.offline = true;
    a = await phone('a');
    expect(dump(a), serverDump());
    await a.dispose();
  });

  test('changes are sent in the order they were made', () async {
    final a = await phone('a');
    server.offline = true;
    final id = a.store.createProject({'name': 'Short-lived'}, []);
    final p = a.data.byId[id]!;
    a.store.updateProject(p, form(p, {'name': 'Renamed'}), []);
    a.store.deleteProject(a.data.byId[id]!);
    expect(a.data.projects, isEmpty);
    server.offline = false;
    await sync(a);
    expect(server.projects, isEmpty);
    expect(server.deleted, contains(id));
    expect(notice(a), isNull);
    await a.dispose();
  });

  test('deleted on one phone while edited offline on the other: refused, explained, gone on both', () async {
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Doomed'}, []);
    a.store.createProject({'name': 'Kept'}, []);
    await sync(a);
    await sync(b);

    server.offline = true;
    b.store.updateProject(byTitle(b, 'Doomed'), form(byTitle(b, 'Doomed'), {'notes': 'still want it'}), []);
    b.store.moveProject(byTitle(b, 'Kept'), 'doing');
    server.offline = false;
    a.store.deleteProject(byTitle(a, 'Doomed'));
    await sync(a);
    await sync(b);
    expect(notice(b), "Couldn't save \"Doomed\": this project was deleted on another device");
    expect(b.data.queue, isEmpty, reason: 'a refusal leaves the queue; the next change still went');
    expect(byTitle(b, 'Kept').status, 'doing');
    await sync(a);
    expect(dump(a), dump(b));
    expect(dump(a), serverDump());
    await a.dispose();
    await b.dispose();
  });

  test('a create sent again after another phone deleted it does not bring it back', () async {
    final a = await phone('a');
    final b = await phone('b');
    a.store.createProject({'name': 'Ghost'}, []);
    server.loseNextChange = true;
    await sync(a); // the server has it, A doesn't know
    await sync(b);
    b.store.deleteProject(byTitle(b, 'Ghost'));
    await sync(b);
    await sync(a); // A sends the create again
    expect(server.projects, isEmpty);
    expect(a.data.projects, isEmpty);
    expect(a.data.queue, isEmpty);
    await a.dispose();
    await b.dispose();
  });

  test('an idea using a category deleted elsewhere is still saved, without that category', () async {
    final games = await category('games');
    final web = await category('web');
    final a = await phone('a');
    await sync(a);
    server.offline = true;
    a.store.createProject({'name': 'Linked'}, [games, web]);
    server.offline = false;
    server.handle('DELETE', '/api/categories/$games', null);
    await sync(a);
    expect(notice(a), isNull);
    expect(byTitle(a, 'Linked').categoryIds, [web]);
    expect(dump(a), serverDump());
    await a.dispose();
  });

  test('server down and a refused token keep the queue; nothing is lost', () async {
    final a = await phone('a');
    a.store.createProject({'name': 'Patient'}, []);
    server.serverDown = true;
    await sync(a);
    expect(stateOf(a), SyncState.offline);
    expect(a.data.queue.length, 1);
    server.serverDown = false;
    server.accessDenied = true;
    await sync(a);
    expect(stateOf(a), SyncState.accessDenied);
    expect(a.data.queue.length, 1);
    server.accessDenied = false;
    await sync(a);
    expect(stateOf(a), SyncState.synced);
    expect(server.projects.length, 1);
    await a.dispose();
  });

  test('an invalid change is refused, dropped and explained, and the rest goes through', () async {
    final a = await phone('a');
    a.store.createProject({'name': 'Bad', 'difficulty': 'Impossible'}, []);
    a.store.createProject({'name': 'Good'}, []);
    await sync(a);
    expect(notice(a), "Couldn't save \"Bad\": a field has an invalid value");
    expect(a.data.projects.map((p) => p.name), ['Good']);
    expect(dump(a), serverDump());
    await a.dispose();
  });
}
