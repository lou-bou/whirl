import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'data/db.dart';
import 'data/store.dart';
import 'data/text.dart';

Future<void> main() async {
  // Loads the saved connection, every idea, category and queued change from SQLite, so the
  // first frame already shows them. The network is only used after that.
  final boot = await KitBoot.start();
  final support = await getApplicationSupportDirectory();
  final db = await LocalDb.open('${support.path}/whirl.db');
  final initial = await loadInitial(db);
  algiers; // The time zone database, for dates.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(
    ProviderScope(
      overrides: [
        ...boot.overrides,
        localDbProvider.overrideWithValue(db),
        initialDataProvider.overrideWithValue(initial),
      ],
      child: const WhirlApp(),
    ),
  );
}
