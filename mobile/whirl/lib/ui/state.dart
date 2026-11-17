import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';

import '../data/store.dart';
import '../data/sync.dart';

/// Which tab the shell shows: Backlog, Wheel, Board, Settings.
class TabIndex extends Notifier<int> {
  @override
  int build() => 0;
  void go(int i) => state = i;
}

final tabProvider = NotifierProvider<TabIndex, int>(TabIndex.new);

const backlogTab = 0, wheelTab = 1, boardTab = 2, settingsTab = 3;

/// The splash plays once per launch. Tests and screenshots turn it off.
final splashProvider = Provider<bool>((_) => true);

/// The filters shared by the Backlog and the Wheel (src/App.jsx NO_FILTERS). Categories are
/// kept by name, like the web app's.
class Filters {
  const Filters({
    this.category = const {},
    this.difficulty = const {},
    this.devType = const {},
    this.status = const {},
    this.content = const {},
  });
  final Set<String> category, difficulty, devType, status, content;

  int get count => category.length + difficulty.length + devType.length + status.length + content.length;

  Set<String> group(String key) => switch (key) {
    'category' => category,
    'difficulty' => difficulty,
    'devType' => devType,
    'status' => status,
    _ => content,
  };

  Filters toggled(String key, String value) {
    Set<String> t(Set<String> s) => s.contains(value) ? ({...s}..remove(value)) : {...s, value};
    return Filters(
      category: key == 'category' ? t(category) : category,
      difficulty: key == 'difficulty' ? t(difficulty) : difficulty,
      devType: key == 'devType' ? t(devType) : devType,
      status: key == 'status' ? t(status) : status,
      content: key == 'content' ? t(content) : content,
    );
  }

  bool matches(Project p, List<Category> categories) {
    if (category.isNotEmpty) {
      final ids = {
        for (final c in categories)
          if (category.contains(c.name)) c.id,
      };
      if (!p.categoryIds.any(ids.contains)) return false;
    }
    if (difficulty.isNotEmpty && !difficulty.contains(p.difficulty)) return false;
    if (devType.isNotEmpty && !devType.contains(p.devType)) return false;
    if (status.isNotEmpty && !status.contains(p.status)) return false;
    if (content.isNotEmpty && !content.any((f) => (f == 'Made') == p.hasContent)) return false;
    return true;
  }
}

class FiltersNotifier extends Notifier<Filters> {
  @override
  Filters build() => const Filters();
  void toggle(String key, String value) => state = state.toggled(key, value);
  void clear() => state = const Filters();
}

final filtersProvider = NotifierProvider<FiltersNotifier, Filters>(FiltersNotifier.new);

class Search extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final searchProvider = NotifierProvider<Search, String>(Search.new);

/// The Backlog: filters and the search over title and description.
final backlogProvider = Provider<List<Project>>((ref) {
  final data = ref.watch(storeProvider);
  final filters = ref.watch(filtersProvider);
  final q = ref.watch(searchProvider).toLowerCase();
  return [
    for (final p in data.projects)
      if (filters.matches(p, data.categories) &&
          (q.isEmpty || p.name.toLowerCase().contains(q) || (p.description ?? '').toLowerCase().contains(q)))
        p,
  ];
});

/// What the wheel spins: the filters, and only ideas unless a status filter says otherwise.
/// Search narrows the Backlog only, since it isn't visible on the Wheel.
final poolProvider = Provider<List<Project>>((ref) {
  final data = ref.watch(storeProvider);
  final filters = ref.watch(filtersProvider);
  return [
    for (final p in data.projects)
      if (filters.matches(p, data.categories) && (filters.status.isNotEmpty || p.status == 'idea')) p,
  ];
});

/// Asks the wheel to spin (the Spin buttons on the Backlog and the result sheet).
class SpinRequest extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

final spinRequestProvider = NotifierProvider<SpinRequest, int>(SpinRequest.new);

/// The project that was just completed, for its short teal burst.
class Burst extends Notifier<String?> {
  Timer? _t;
  @override
  String? build() {
    ref.onDispose(() => _t?.cancel());
    return null;
  }

  void celebrate(String id) {
    state = id;
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 650), () => state = null);
  }
}

final burstProvider = NotifierProvider<Burst, String?>(Burst.new);

const _none = <String>{};

/// Projects with changes still queued. While online the queue empties in a moment, and marking
/// that would only make cards flicker on every edit, so this only counts when something is
/// holding the queue back (as in Tack).
final unsentProvider = Provider<Set<String>>((ref) {
  final stalled = ref.watch(syncProvider.select((s) => s.stalled));
  if (!stalled) return _none;
  return {for (final op in ref.watch(storeProvider.select((d) => d.queue))) op.projectId};
});

/// The current time, refreshed each minute so "updated 3h" moves on by itself.
class NowTicker extends Notifier<DateTime> {
  @override
  DateTime build() {
    final clock = ref.watch(wallClockProvider);
    final timer = Timer.periodic(const Duration(minutes: 1), (_) => state = _at(clock));
    ref.onDispose(timer.cancel);
    return _at(clock);
  }

  static DateTime _at(int Function() clock) => DateTime.fromMillisecondsSinceEpoch(clock(), isUtc: true);
  void refresh() => state = _at(ref.read(wallClockProvider));
}

final nowProvider = NotifierProvider<NowTicker, DateTime>(NowTicker.new);

/// Vibrate as the wheel ticks past slices and lands. On by default; a phone setting.
const hapticsPref = 'spinHaptics';
final hapticsProvider = Provider<bool>((ref) => ref.watch(prefProvider(hapticsPref)) != 'off');
