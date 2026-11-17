import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:whirl/data/store.dart';
import 'package:whirl/data/sync.dart';

import 'fake_server.dart';

/// 17/11/2026 10:30 in Algiers.
final seedNow = DateTime.utc(2026, 11, 17, 9, 30).millisecondsSinceEpoch;

/// A believable backlog on the server, synced to the phone. Returns ids by name.
Future<Map<String, String>> seedIdeas(ProviderContainer c, FakeWhirl server) async {
  final ids = <String, String>{};
  String category(String name) {
    final (_, body) = server.handle('POST', '/api/categories', {'name': name});
    return ids[name] = (body as Map)['id'] as String;
  }

  final web = category('Web');
  final games = category('Games');
  final tools = category('Tools');
  final hardware = category('Hardware');
  final learning = category('Learning');

  var n = 0;
  void idea(
    String name, {
    String status = 'idea',
    String difficulty = 'Medium',
    String devType = 'Assisted',
    List<String> cats = const [],
    String? description,
    bool content = false,
    String? link,
    String? notes,
    int daysAgo = 0,
    int hoursAgo = 0,
  }) {
    final id = '${(++n).toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000';
    server.handle('POST', '/api/projects', {
      'id': id,
      'name': name,
      'status': status,
      'difficulty': difficulty,
      'dev_type': devType,
      'description': description,
      'has_content': content,
      'link': link,
      'notes': notes,
      'categoryIds': cats,
    });
    final at = DateTime.fromMillisecondsSinceEpoch(
      seedNow - Duration(days: daysAgo, hours: hoursAgo).inMilliseconds,
      isUtc: true,
    ).toIso8601String();
    final created = DateTime.fromMillisecondsSinceEpoch(
      seedNow - Duration(days: daysAgo + 12).inMilliseconds,
      isUtc: true,
    ).toIso8601String();
    server.projects[id] = {...server.projects[id]!, 'updated_at': at, 'created_at': created};
    ids[name] = id;
  }

  idea(
    'Recipe scaler',
    difficulty: 'Easy',
    cats: [web],
    description: '# Recipe scaler\nPaste a recipe, pick the servings, get **scaled** amounts.\n- Parse fractions like `1 1/2`\n- Convert cups to grams\n- Remember the last *ten* recipes\n\nInspired by [this thread](https://example.com/recipes).',
    link: 'https://github.com/lou-bou/recipe-scaler\nhttps://example.com/recipes',
    notes: 'Start with the parser.',
    daysAgo: 3,
  );
  idea(
    'Pixel garden',
    devType: 'Manual',
    cats: [games],
    description: 'A tiny farming game where plants grow in real time.',
    content: true,
    daysAgo: 9,
  );
  idea(
    'Home lab dashboard',
    status: 'doing',
    difficulty: 'Hard',
    cats: [hardware, web],
    description: 'Temperatures, disk space and backups of the ThinkPad on one page.',
    hoursAgo: 5,
  );
  idea(
    'Habit streaks',
    status: 'completed',
    difficulty: 'Easy',
    cats: [web],
    description: 'Mark a habit done each day and watch the streak grow.',
    content: true,
    daysAgo: 40,
  );
  idea(
    'Synth in the browser',
    difficulty: 'Expert',
    devType: 'Manual',
    cats: [web, learning],
    description: 'Oscillators, filters and a keyboard, with the Web Audio API.',
    daysAgo: 21,
  );
  idea('CLI for backups', cats: [tools], description: 'One command to back up and check the databases.', daysAgo: 2);
  idea(
    'Plant watering bot',
    difficulty: 'Hard',
    devType: 'Manual',
    cats: [hardware],
    description: 'An ESP32, a pump and a moisture sensor.',
    daysAgo: 60,
  );
  idea(
    'Chess puzzles trainer',
    status: 'doing',
    devType: 'Manual',
    cats: [games, learning],
    description: 'Spaced repetition for the puzzles I get wrong.',
    daysAgo: 1,
  );
  idea(
    'Markdown slides',
    difficulty: 'Easy',
    cats: [tools],
    description: 'Write slides in Markdown, present from the browser.',
    daysAgo: 14,
  );
  idea('Reading list sync', status: 'completed', cats: [tools], daysAgo: 120);
  idea('Arabic flashcards', cats: [learning], description: 'Cards with audio, sorted by root.', daysAgo: 6);
  await c.read(syncProvider.notifier).sync();
  await c.read(storeProvider.notifier).flushed;
  return ids;
}
