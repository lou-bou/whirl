import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../data/api.dart';
import '../data/store.dart';
import '../data/sync.dart';
import 'backlog_page.dart';
import 'board_page.dart';
import 'settings_page.dart';
import 'state.dart';
import 'wheel_page.dart';
import 'widgets/common.dart';
import 'widgets/logo.dart';

/// The header's mark, where the splash lands. The header sits outside the tabs, so there is one.
final logoKey = GlobalKey();

/// The app once connected: the header, four tabs, and sync kept running (on open, on resume,
/// when the network returns, just after an edit, and every 30 seconds while open).
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> with WidgetsBindingObserver {
  Timer? _poll;
  Timer? _soon;
  StreamSubscription<void>? _net;
  StreamSubscription<void>? _local;
  late bool _splash = ref.read(splashProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _net = ref.read(networkRegainedProvider).listen((_) => _sync(), onError: (_) {});
    _local = ref.read(storeProvider.notifier).localChanges.listen((_) {
      // Soon after an edit, but one request for a burst of them.
      _soon?.cancel();
      _soon = Timer(const Duration(milliseconds: 600), _sync);
    });
    _startPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _sync());
  }

  void _sync() => unawaited(ref.read(syncProvider.notifier).sync());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(nowProvider.notifier).refresh();
      _sync();
      _startPolling();
    } else if (state == AppLifecycleState.paused) {
      // Send what's queued before Android stops the app, and stop polling in the background.
      _sync();
      _poll?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _soon?.cancel();
    _net?.cancel();
    _local?.cancel();
    super.dispose();
  }

  /// Back: to the Backlog from any other tab, then out of the app.
  void _back() {
    if (ref.read(tabProvider) != backlogTab) {
      ref.read(tabProvider.notifier).go(backlogTab);
      return;
    }
    SystemNavigator.pop();
  }

  void _openConnection() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => ConnectionScreen(
        appName: 'Whirl',
        healthPath: WhirlApi.healthPath,
        isHealthy: WhirlApi.isHealthy,
        onSaved: () {
          Navigator.of(context).pop();
          _sync();
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(tabProvider);
    final t = context.kit;
    final sync = ref.watch(syncProvider);
    final queued = ref.watch(storeProvider.select((d) => d.queue.length));
    final notice = ref.watch(noticeProvider);
    final ready = ref.watch(storeProvider.select((d) => d.loaded || d.projects.isNotEmpty)) || sync.stalled;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle(t, Theme.of(context).brightness),
        child: Stack(
          children: [
            Scaffold(
              backgroundColor: t.bg,
              body: Column(
                children: [
                  _Header(sync: sync, queued: queued),
                  if (sync.state == SyncState.accessDenied)
                    Strip(
                      text:
                          'Cloudflare Access refused the service token.'
                          '${queued > 0 ? ' ${plural(queued, 'change')} saved on this device.' : ''}',
                      action: 'Check',
                      onAction: _openConnection,
                    ),
                  if (notice != null)
                    Strip(
                      text: notice,
                      danger: true,
                      action: 'Dismiss',
                      onAction: () => ref.read(noticeProvider.notifier).show(null),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: tab,
                      children: const [BacklogPage(), WheelPage(), BoardPage(), SettingsPage()],
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: const _TabBar(),
            ),
            if (_splash)
              Positioned.fill(
                child: Splash(target: logoKey, ready: ready, onDone: () => setState(() => _splash = false)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The mark and "Whirl", and a quiet pill when offline or sending (DESIGN.md §9).
class _Header extends StatelessWidget {
  const _Header({required this.sync, required this.queued});
  final SyncStatus sync;
  final int queued;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final pill = switch (sync.state) {
      SyncState.offline => 'Offline · changes will sync',
      SyncState.syncing || SyncState.synced when queued > 0 => 'Saving $queued…',
      _ => null,
    };
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s4),
          child: Row(
            children: [
              Semantics(header: true, child: Wordmark(markKey: logoKey)),
              const SizedBox(width: Space.s3),
              Expanded(
                child: Text(
                  pill ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Backlog, Wheel, Board, Settings.
class _TabBar extends ConsumerWidget {
  const _TabBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.kit;
    final tab = ref.watch(tabProvider);
    const tabs = [
      (LucideIcons.list, 'Backlog'),
      (LucideIcons.shipWheel, 'Wheel'),
      (LucideIcons.squareKanban, 'Board'),
      (LucideIcons.settings, 'Settings'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            for (final (i, (icon, label)) in tabs.indexed)
              Expanded(
                child: Semantics(
                  selected: i == tab,
                  button: true,
                  label: label,
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (i != tab) HapticFeedback.selectionClick();
                      ref.read(tabProvider.notifier).go(i);
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: Motion.fast,
                          width: 56,
                          height: 30,
                          decoration: BoxDecoration(
                            color: i == tab ? t.surfaceSunken : null,
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Icon(icon, size: 20, color: i == tab ? t.text : t.textMuted),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          label,
                          style: context.text.labelMedium!.copyWith(
                            color: i == tab ? t.text : t.textMuted,
                            fontWeight: i == tab ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
