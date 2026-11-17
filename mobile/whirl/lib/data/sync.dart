import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';

import 'api.dart';
import 'store.dart';

enum SyncState { syncing, synced, offline, accessDenied, notConfigured }

class SyncStatus {
  const SyncStatus({this.state = SyncState.syncing, this.message});
  final SyncState state;
  final String? message;

  /// Something is holding the queue back, so unsent changes are worth marking.
  bool get stalled => state != SyncState.syncing && state != SyncState.synced;

  /// Category changes go straight to the server, so they need it to be answering.
  bool get online => state == SyncState.syncing || state == SyncState.synced;
}

/// "Couldn't save …" after the server refused queued changes, or a category change failed.
class Notice extends Notifier<String?> {
  @override
  String? build() => null;
  void show(String? message) => state = message;
}

final noticeProvider = NotifierProvider<Notice, String?>(Notice.new);

/// Sends the device queue, then fetches everything (src/offline.js flushQueue + fetchData).
///
/// Changes go oldest first, one at a time. One leaves the queue only once the server confirms
/// it, or refuses it for good (4xx, then the user is told); a connection problem stops the run
/// and keeps the rest for later, and the data is only fetched once the queue went through.
/// Safe to repeat: creates carry their own id and edits their edit time, so a change sent twice
/// changes nothing.
class SyncEngine extends Notifier<SyncStatus> {
  Future<void>? _running;
  bool _again = false;

  WhirlApi get _api => ref.read(whirlApiProvider);
  WhirlStore get _store => ref.read(storeProvider.notifier);

  @override
  SyncStatus build() => const SyncStatus();

  /// One run at a time. A request during a run causes exactly one more afterwards.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    _running = () async {
      try {
        var runs = 0;
        do {
          _again = false;
          await _runOnce();
        } while (_again && ++runs < 5 && ref.mounted);
      } finally {
        _running = null;
      }
    }();
    return _running!;
  }

  void _set(SyncState s, {String? message}) {
    if (!ref.mounted) return;
    state = SyncStatus(state: s, message: message);
  }

  /// Something showed the server is not answering (a category change, for instance).
  void report(ApiException e) => _set(_stateFor(e), message: e.message);

  static SyncState _stateFor(ApiException e) => switch (e.kind) {
    ApiFailure.accessDenied => SyncState.accessDenied,
    ApiFailure.notConfigured => SyncState.notConfigured,
    _ => SyncState.offline,
  };

  Future<void> _runOnce() async {
    if (ref.read(connectionProvider) == null) {
      _set(SyncState.notConfigured);
      return;
    }
    if (state.state != SyncState.synced) _set(SyncState.syncing);
    final now = ref.read(wallClockProvider);
    try {
      await _flush();
      if (!ref.mounted) return;
      final sentAt = now();
      final data = await _api.data();
      if (!ref.mounted) return;
      await _store.applyServerData(data, sentAt: sentAt, receivedAt: now());
      if (!ref.mounted) return;
      if (ref.read(storeProvider).queue.isNotEmpty) _again = true;
      _set(SyncState.synced);
    } on ApiException catch (e) {
      _again = false;
      _set(_stateFor(e), message: e.message);
    }
  }

  Future<void> _flush() async {
    final failed = <(String, String)>[];
    try {
      while (ref.mounted) {
        final op = ref.read(storeProvider).queue.firstOrNull;
        if (op == null) break;
        try {
          final answer = await _api.send(op);
          if (!ref.mounted) return;
          await _store.confirmed(op, answer);
        } on ApiException catch (e) {
          if (!ref.mounted || !isRefusal(e)) rethrow;
          await _store.refused(op);
          failed.add((op.label, e.message));
        }
      }
    } finally {
      if (failed.isNotEmpty && ref.mounted) {
        ref
            .read(noticeProvider.notifier)
            .show("Couldn't save ${failed.map((f) => '"${f.$1}"').join(', ')}: ${failed.first.$2}");
      }
    }
  }
}

final syncProvider = NotifierProvider<SyncEngine, SyncStatus>(SyncEngine.new);
