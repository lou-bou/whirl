// Renders every screen to PNG with the real fonts, for a visual check without a phone:
//
//   flutter test tool/screenshots_test.dart --update-goldens
//
// Images land in build/screens/. Not part of the normal test run. Uses the real SQLite store,
// the real sync and a fake server, at a fixed time (17/11/2026 10:30) and a seeded wheel.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:whirl/app.dart';
import 'package:whirl/data/sync.dart';
import 'package:whirl/ui/backlog_page.dart';
import 'package:whirl/ui/shell.dart';
import 'package:whirl/ui/state.dart';
import 'package:whirl/ui/wheel_page.dart';

import '../test/fake_server.dart';
import '../test/seed.dart';

Future<void> loadAppFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in entry['fonts'] as List) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

void main() {
  late Directory dir;
  late FakeWhirl server;

  setUpAll(loadAppFonts);

  Future<(Client, Map<String, String>)> launch(
    WidgetTester tester, {
    bool dark = false,
    bool seed = true,
    bool connected = true,
    bool splash = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    tester.view.padding = const FakeViewPadding(top: 66, bottom: 44);
    tester.view.viewPadding = const FakeViewPadding(top: 66, bottom: 44);
    addTearDown(tester.view.reset);
    late Client c;
    var ids = <String, String>{};
    await tester.runAsync(() async {
      dir = Directory.systemTemp.createTempSync('whirl_shots');
      server = FakeWhirl(now: () => seedNow);
      c = await Client.start(
        server,
        dir,
        connected: connected,
        clock: () => seedNow,
        splash: splash,
        extra: [wheelRandomProvider.overrideWithValue(Random(7))],
      );
      if (seed) ids = await seedIdeas(c.container, server);
      if (dark) c.container.read(prefsProvider.notifier).set(themeModePref, 'dark');
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c.container, child: const WhirlApp()));
    await real(tester, 8);
    return (c, ids);
  }

  Future<void> shot(WidgetTester tester, String name, {bool wait = true}) async {
    if (wait) await settle(tester);
    await expectLater(find.byType(WhirlApp), matchesGoldenFile('../build/screens/$name.png'));
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

  Future<void> tab(WidgetTester tester, String label) async {
    final bar = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TabBar');
    await tester.tap(find.descendant(of: bar, matching: find.text(label)));
    await settle(tester);
  }

  /// The Android Back button.
  Future<void> back(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    );
    await settle(tester);
  }

  /// Pumps [ms] of animation in frames.
  Future<void> frames(WidgetTester tester, int ms) async {
    for (var t = 0; t < ms; t += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('light', (tester) async {
    final (c, ids) = await launch(tester);
    await shot(tester, '01-backlog');

    await tester.tap(find.text('Games').first);
    await tester.tap(find.text('Learning').first);
    await settle(tester);
    await shot(tester, '02-backlog-filtered');

    await tab(tester, 'Wheel');
    await shot(tester, '03-wheel-filtered');
    c.container.read(filtersProvider.notifier).clear();
    await settle(tester);
    await shot(tester, '04-wheel');

    await tester.tap(find.text('Spin'));
    await frames(tester, 900);
    await shot(tester, '05-wheel-mid-spin', wait: false);
    await frames(tester, 1400);
    await shot(tester, '06-wheel-slowing', wait: false);
    await frames(tester, 3000);
    await settle(tester);
    await shot(tester, '07-spin-result');
    await back(tester);

    await tester.tap(find.text('Filters'));
    await settle(tester);
    await shot(tester, '08-filter-sheet');
    await back(tester);

    await tab(tester, 'Board');
    await shot(tester, '09-board-idea');
    await tester.tap(find.text('Doing').first);
    await settle(tester);
    await shot(tester, '10-board-doing');
    await tester.tap(find.text('Idea').first);
    await settle(tester);

    // Mid-drag: a card lifted over the Doing tab.
    final from = tester.getCenter(find.text('Arabic flashcards'));
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 450));
    await gesture.moveTo(from + const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(find.text('Doing').first));
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, '11-board-drag', wait: false);
    await gesture.up();
    await settle(tester);
    expect(c.data.byId[ids['Arabic flashcards']]!.status, 'doing');
    await shot(tester, '12-board-dropped');

    openIdea(tester.element(find.byType(Shell)), ids['Recipe scaler']);
    await settle(tester);
    await shot(tester, '13-idea');
    await tester.tap(find.text('Preview'));
    await settle(tester);
    await shot(tester, '14-idea-preview');
    await tester.drag(find.byType(ListView).last, const Offset(0, -900));
    await settle(tester);
    await shot(tester, '15-idea-lower');
    await back(tester);

    await tab(tester, 'Backlog');
    await tester.tap(find.text('New idea'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).first, 'Weather wall');
    await settle(tester);
    await shot(tester, '16-new-idea');
    await back(tester); // asks to discard
    await shot(tester, '17-discard');
    await tester.tap(find.text('Discard'));
    await settle(tester);

    await tab(tester, 'Settings');
    await shot(tester, '18-settings');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await settle(tester);
    await shot(tester, '19-settings-lower');
    await close(tester, c);
  });

  testWidgets('dark', (tester) async {
    final (c, ids) = await launch(tester, dark: true);
    await shot(tester, '20-backlog-dark');
    await tab(tester, 'Wheel');
    await shot(tester, '21-wheel-dark');
    await tester.tap(find.text('Spin'));
    await frames(tester, 1100);
    await shot(tester, '22-wheel-mid-spin-dark', wait: false);
    await frames(tester, 5000);
    await settle(tester);
    await shot(tester, '23-spin-result-dark');
    await back(tester);
    await tab(tester, 'Board');
    await shot(tester, '24-board-dark');
    openIdea(tester.element(find.byType(Shell)), ids['Home lab dashboard']);
    await settle(tester);
    await shot(tester, '25-idea-dark');
    await back(tester);
    await tab(tester, 'Settings');
    await shot(tester, '26-settings-dark');
    await close(tester, c);
  });

  testWidgets('offline with changes waiting, and a refusal', (tester) async {
    final (c, ids) = await launch(tester);
    server.offline = true;
    final p = c.data.byId[ids['Pixel garden']]!;
    c.store.moveProject(p, 'doing');
    c.container
        .read(noticeProvider.notifier)
        .show("Couldn't save \"Old idea\": this project was deleted on another device");
    await tester.runAsync(() => c.container.read(syncProvider.notifier).sync());
    await settle(tester);
    await shot(tester, '30-offline');
    await tab(tester, 'Settings');
    await shot(tester, '31-settings-offline');
    await close(tester, c);
  });

  testWidgets('empty wheel', (tester) async {
    final (c, _) = await launch(tester);
    c.container.read(filtersProvider.notifier).toggle('difficulty', 'Expert');
    c.container.read(filtersProvider.notifier).toggle('devType', 'Assisted');
    await tab(tester, 'Wheel');
    await shot(tester, '32-wheel-empty');
    await close(tester, c);
  });

  testWidgets('first run', (tester) async {
    final (c, _) = await launch(tester, seed: false, connected: false);
    await shot(tester, '40-connect');
    await close(tester, c);
  });

  testWidgets('splash', (tester) async {
    final (c, _) = await launch(tester, splash: true);
    await tester.pump(const Duration(milliseconds: 180));
    await shot(tester, '41-splash-pop', wait: false);
    await tester.pump(const Duration(milliseconds: 400));
    await shot(tester, '42-splash-drop', wait: false);
    await frames(tester, 520);
    await shot(tester, '43-splash-whirl', wait: false);
    await frames(tester, 680);
    await shot(tester, '44-splash-fly', wait: false);
    await frames(tester, 800);
    await close(tester, c);
  });
}

/// Let real I/O (SQLite) finish, pumping frames in between.
Future<void> real(WidgetTester tester, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// pumpAndSettle that also lets SQLite writes land.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await real(tester, 4);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
