import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:whirl/app.dart';
import 'package:whirl/data/sync.dart';
import 'package:whirl/ui/state.dart';
import 'package:whirl/ui/wheel_page.dart';

import 'fake_server.dart';
import 'seed.dart';

/// The real app on a phone-sized screen: real SQLite, real sync, fake server, fixed time.
void main() {
  late Directory dir;
  late FakeWhirl server;

  Future<void> real(WidgetTester tester, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await real(tester, 4);
  }

  Future<(Client, Map<String, String>)> launch(
    WidgetTester tester, {
    bool connected = true,
    bool seed = true,
    bool offline = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    late Client c;
    var ids = <String, String>{};
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('whirl_app');
      server = FakeWhirl(now: () => seedNow);
      c = await Client.start(
        server,
        dir,
        connected: connected,
        clock: () => seedNow,
        extra: [wheelRandomProvider.overrideWithValue(Random(3))],
      );
      if (seed) ids = await seedIdeas(c.container, server);
      server.offline = offline;
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c.container, child: const WhirlApp()));
    await real(tester);
    return (c, ids);
  }

  Future<void> close(WidgetTester tester, Client c) async {
    await tester.pumpWidget(const SizedBox());
    await real(tester, 5);
    await tester.pump(const Duration(seconds: 30));
    await tester.runAsync(() async {
      await c.dispose();
      dir.deleteSync(recursive: true);
    });
  }

  /// Starts a sync and pumps until it has landed. The app may already be syncing in the test's
  /// fake time, so awaiting the run from real time would never finish.
  Future<void> syncNow(WidgetTester tester, Client c) async {
    unawaited(c.container.read(syncProvider.notifier).sync());
    await real(tester, 25);
  }

  Future<void> tab(WidgetTester tester, String label) async {
    final bar = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabBar');
    await tester.tap(find.descendant(of: bar, matching: find.text(label)));
    await settle(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await settle(tester);
  }

  testWidgets('first run: a refused token is explained, a good one connects and loads the ideas', (tester) async {
    final (c, _) = await launch(tester, connected: false, seed: false);
    expect(find.text('Connect to your server'), findsOneWidget);
    server.handle('POST', '/api/categories', {'name': 'Web'});
    server.handle('POST', '/api/projects', {'id': '00000001-0000-4000-8000-000000000000', 'name': 'First idea'});
    server.accessDenied = true;
    await tester.enterText(find.byType(EditableText).at(0), 'wheel.test');
    await tester.enterText(find.byType(EditableText).at(1), 'id.access');
    await tester.enterText(find.byType(EditableText).at(2), 'secret');
    await tester.tap(find.text('Test and save'));
    await real(tester, 15);
    expect(find.textContaining('Cloudflare Access refused'), findsOneWidget);
    server.accessDenied = false;
    await tester.tap(find.text('Test and save'));
    await real(tester, 25);
    expect(find.text('First idea'), findsOneWidget);
    expect(find.text('1 of 1'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('opens offline from the phone alone, edits wait in the queue and go out later', (tester) async {
    final (c, ids) = await launch(tester, offline: true);
    await syncNow(tester, c);
    expect(find.text('Offline · changes will sync'), findsOneWidget);
    expect(find.text('Arabic flashcards'), findsOneWidget);

    await tester.tap(find.text('CLI for backups'));
    await settle(tester);
    await tester.tap(find.text('Doing').last);
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(c.data.queue.length, 1);
    expect(find.text('Saved on this device'), findsOneWidget, reason: 'marked while the queue is stuck');

    server.offline = false;
    await syncNow(tester, c);
    expect(server.projects[ids['CLI for backups']]!['status'], 'doing');
    expect(c.data.queue, isEmpty);
    expect(find.text('Saved on this device'), findsNothing);
    expect(find.text('Offline · changes will sync'), findsNothing);
    await close(tester, c);
  });

  testWidgets('search and filters narrow the Backlog; the Wheel spins ideas only', (tester) async {
    final (c, _) = await launch(tester);
    expect(find.text('11 of 11'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, 'chess');
    await settle(tester);
    expect(find.text('1 of 11'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '');
    await tester.tap(find.text('Hardware').first);
    await settle(tester);
    expect(find.text('2 of 11'), findsOneWidget);
    await tab(tester, 'Wheel');
    expect(find.textContaining('Spinning from'), findsOneWidget);
    expect(c.container.read(poolProvider).map((p) => p.name), [
      'Plant watering bot',
    ], reason: 'Home lab dashboard is Doing, and the wheel spins ideas');
    await close(tester, c);
  });

  testWidgets('a spin lands on an idea, and Start building moves it to Doing on the server', (tester) async {
    final (c, ids) = await launch(tester);
    await tab(tester, 'Wheel');
    await tester.tap(find.text('Spin'));
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester);
    expect(find.text('Start building'), findsOneWidget);
    final picked = c.container.read(poolProvider).where((p) => find.text(p.name).evaluate().isNotEmpty).toList();
    expect(picked, isNotEmpty);
    await tester.tap(find.text('Start building'));
    await settle(tester);
    await syncNow(tester, c);
    final moved = [
      for (final e in ids.entries)
        if (server.projects[e.value]?['status'] == 'doing') e.key,
    ];
    expect(moved.length, 3, reason: 'the two already in Doing, and the pick');
    await close(tester, c);
  });

  testWidgets('a fling of the wheel spins it too', (tester) async {
    final (c, _) = await launch(tester);
    await tab(tester, 'Wheel');
    final wheel = find.bySemanticsLabel(RegExp(r'^Wheel with'));
    final centre = tester.getCenter(wheel);
    await tester.flingFrom(centre + const Offset(-120, -60), const Offset(240, 0), 2500);
    for (var i = 0; i < 450; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester);
    expect(find.text('Start building'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('on the Board, a card dropped on a tab changes status, and the Board follows it', (tester) async {
    final (c, ids) = await launch(tester);
    await tab(tester, 'Board');
    final from = tester.getCenter(find.text('Arabic flashcards'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 450));
    await gesture.moveTo(from + const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(find.text('Completed').first));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await settle(tester);
    await syncNow(tester, c);
    expect(server.projects[ids['Arabic flashcards']]!['status'], 'completed');
    expect(find.text('Habit streaks'), findsOneWidget, reason: 'now showing Completed');
    await close(tester, c);
  });

  testWidgets('an idea is created, edited and deleted from its screen', (tester) async {
    final (c, _) = await launch(tester);
    await tester.tap(find.text('New idea'));
    await settle(tester);
    expect(find.text('Save'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, 'Weather wall');
    await tester.tap(find.text('Web').last);
    await tester.tap(find.text('Hard'));
    await settle(tester);
    await tester.tap(find.text('Save'));
    await settle(tester);
    await syncNow(tester, c);
    final made = server.projects.values.firstWhere((p) => p['name'] == 'Weather wall');
    expect(made['difficulty'], 'Hard');
    expect(server.links[made['id']]!.length, 1);

    await tester.enterText(find.byType(EditableText).first, 'weather');
    await settle(tester);
    await tester.tap(find.text('Weather wall'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).first, 'Weather wall v2');
    await tester.tap(find.text('Save'));
    await settle(tester);
    await syncNow(tester, c);
    expect(server.projects[made['id']]!['name'], 'Weather wall v2');

    await tester.tap(find.text('Weather wall v2'));
    await settle(tester);
    await tester.tap(find.byTooltip('Delete idea'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    await syncNow(tester, c);
    expect(server.projects.containsKey(made['id']), false);
    expect(find.text('Weather wall v2'), findsNothing);
    await close(tester, c);
  });

  testWidgets('leaving an edited idea asks before discarding', (tester) async {
    final (c, _) = await launch(tester);
    await tester.tap(find.text('Arabic flashcards'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).first, 'Flashcards in Arabic');
    await back(tester);
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await settle(tester);
    expect(find.text('Edit idea'), findsOneWidget);
    await back(tester);
    await tester.tap(find.text('Discard'));
    await settle(tester);
    expect(find.text('Arabic flashcards'), findsOneWidget);
    expect(c.data.queue, isEmpty);
    await close(tester, c);
  });

  testWidgets('categories need the server: read-only offline, added online', (tester) async {
    final (c, _) = await launch(tester);
    await tab(tester, 'Settings');
    await tester.enterText(find.widgetWithText(TextField, 'New category'), 'Music');
    await tester.tap(find.text('Add'));
    await real(tester, 20);
    expect(server.categories.values.any((x) => x['name'] == 'Music'), true);
    expect(find.text('Music'), findsOneWidget);

    server.offline = true;
    await syncNow(tester, c);
    expect(find.textContaining('Category changes need a connection'), findsOneWidget);
    await close(tester, c);
  });

  testWidgets('Back goes to the Backlog from another tab', (tester) async {
    final (c, _) = await launch(tester);
    await tab(tester, 'Board');
    expect(c.container.read(tabProvider), boardTab);
    await back(tester);
    expect(c.container.read(tabProvider), backlogTab);
    await close(tester, c);
  });
}
