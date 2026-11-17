import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

import '../data/store.dart';
import 'backlog_page.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/drag.dart';
import 'widgets/idea_card.dart';

/// The Board (DESIGN.md §6.4): Idea, Doing and Completed, one column at a time, switched with
/// the tabs on top or by swiping. Hold a card, then drop it on a tab (or carry it to the screen
/// edge to turn the page, and drop it in that column). The Board follows the card.
class BoardPage extends ConsumerStatefulWidget {
  const BoardPage({super.key});

  @override
  ConsumerState<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends ConsumerState<BoardPage> {
  final _pages = PageController();
  final _tabKeys = {for (final s in statuses) s: GlobalKey()};
  final _cardKeys = <String, GlobalKey>{};
  final _pagesKey = GlobalKey();
  final _scrolls = {for (final s in statuses) s: ScrollController()};
  final _proxy = DragProxy();
  final _edge = EdgeScroller();

  int _column = 0;
  String? _dragging;
  String? _from;
  String? _over;
  Offset _grab = Offset.zero;
  Timer? _turn;

  GlobalKey _cardKey(String id) => _cardKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void dispose() {
    _turn?.cancel();
    _edge.stop();
    _proxy.hide();
    _pages.dispose();
    for (final s in _scrolls.values) {
      s.dispose();
    }
    super.dispose();
  }

  void _go(int i) {
    if (i == _column) return;
    setState(() => _column = i);
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(i);
    } else {
      _pages.animateToPage(i, duration: const Duration(milliseconds: 260), curve: Motion.easeOut);
    }
  }

  void _start(Project p, Offset global) {
    final rect = rectOf(_cardKey(p.id));
    if (rect == null) return;
    HapticFeedback.mediumImpact();
    _grab = global - rect.topLeft;
    _proxy.show(
      context,
      from: rect,
      child: IdeaCard(project: p, lifted: true),
    );
    setState(() {
      _dragging = p.id;
      _from = p.status;
      _over = null;
    });
  }

  void _move(Offset global) {
    if (_dragging == null) return;
    _proxy.moveTo(global - _grab);
    String? over;
    for (final s in statuses) {
      final r = rectOf(_tabKeys[s]!);
      if (r != null && r.inflate(6).contains(global)) over = s;
    }
    final pages = rectOf(_pagesKey);
    if (over == null && pages != null && pages.contains(global)) over = statuses[_column];
    if (over == _from) over = null;
    if (over != _over) {
      if (over != null) HapticFeedback.selectionClick();
      setState(() => _over = over);
    }
    // Held at the screen's side: turn to the next column.
    final width = MediaQuery.sizeOf(context).width;
    final side = global.dx < 28 ? -1 : (global.dx > width - 28 ? 1 : 0);
    if (side == 0) {
      _turn?.cancel();
      _turn = null;
    } else {
      _turn ??= Timer(const Duration(milliseconds: 450), () {
        _turn = null;
        final next = (_column + side).clamp(0, statuses.length - 1);
        if (next != _column && _dragging != null) {
          HapticFeedback.selectionClick();
          _go(next);
          _move(global);
        }
      });
    }
    final scroll = _scrolls[statuses[_column]];
    _edge.update(scroll, pages, global);
  }

  void _end(bool cancelled) {
    _turn?.cancel();
    _turn = null;
    _edge.stop();
    _proxy.hide();
    final id = _dragging, to = _over;
    setState(() {
      _dragging = null;
      _from = null;
      _over = null;
    });
    if (cancelled || id == null || to == null) return;
    final p = ref.read(storeProvider).byId[id];
    if (p == null) return;
    HapticFeedback.mediumImpact();
    ref.read(storeProvider.notifier).moveProject(p, to);
    if (to == 'completed' && !MediaQuery.disableAnimationsOf(context)) {
      ref.read(burstProvider.notifier).celebrate(id);
    }
    // Follow the card to where it landed.
    _go(statuses.indexOf(to));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final projects = ref.watch(storeProvider.select((d) => d.projects));
    final columns = {
      for (final s in statuses)
        s: [
          for (final p in projects)
            if (p.status == s) p,
        ],
    };
    _cardKeys.removeWhere((id, _) => !projects.any((p) => p.id == id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.s4, Space.s4, Space.s4, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ScreenTitle('Board'),
              const SizedBox(height: Space.s1),
              Text(
                _over != null
                    ? 'Release to move to ${statusLabel[_over]}'
                    : (_dragging != null ? 'Drop it on a tab' : 'Hold a card, then drag it onto a tab.'),
                style: context.text.bodyMedium!.copyWith(color: _over != null ? t.text : t.textMuted),
              ),
              const SizedBox(height: Space.s3),
              _Tabs(
                keys: _tabKeys,
                counts: {for (final s in statuses) s: columns[s]!.length},
                current: statuses[_column],
                over: _over,
                onTap: (s) => _go(statuses.indexOf(s)),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s3),
        Expanded(
          child: PageView(
            key: _pagesKey,
            controller: _pages,
            onPageChanged: (i) => setState(() => _column = i),
            children: [
              for (final s in statuses)
                _ColumnView(
                  status: s,
                  items: columns[s]!,
                  scroll: _scrolls[s]!,
                  dropOver: _over == s && _over == statuses[_column],
                  dragging: _dragging,
                  cardKey: _cardKey,
                  onLift: _start,
                  onMove: _move,
                  onEnd: _end,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Idea, Doing, Completed with their counts; the one under a carried card is outlined in its
/// status colour.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.keys,
    required this.counts,
    required this.current,
    required this.over,
    required this.onTap,
  });
  final Map<String, GlobalKey> keys;
  final Map<String, int> counts;
  final String current;
  final String? over;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final w = context.whirl;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.surfaceSunken, borderRadius: BorderRadius.circular(WhirlRadii.sm)),
      child: Row(
        children: [
          for (final s in statuses)
            Expanded(
              child: Semantics(
                selected: s == current,
                button: true,
                label: '${statusLabel[s]}, ${counts[s]}',
                excludeSemantics: true,
                child: Pressable(
                  scale: 1,
                  onTap: () => onTap(s),
                  child: AnimatedContainer(
                    key: keys[s],
                    duration: Motion.fast,
                    height: 44,
                    margin: EdgeInsets.only(left: s == statuses.first ? 0 : 3),
                    decoration: BoxDecoration(
                      color: s == current ? t.surface : null,
                      borderRadius: BorderRadius.circular(6),
                      border: over == s
                          ? Border.all(color: w.status(s), width: 2)
                          : (s == current ? Border.all(color: t.border) : null),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: Space.s1),
                    // Large system text shrinks the label rather than spilling over.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon(s), size: 16, color: s == current || over == s ? t.text : t.textMuted),
                          const SizedBox(width: 6),
                          Text(
                            statusLabel[s]!,
                            style: context.text.bodyMedium!.copyWith(
                              color: s == current || over == s ? t.text : t.textMuted,
                              fontWeight: s == current ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('${counts[s]}', style: context.mono(12)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ColumnView extends StatelessWidget {
  const _ColumnView({
    required this.status,
    required this.items,
    required this.scroll,
    required this.dropOver,
    required this.dragging,
    required this.cardKey,
    required this.onLift,
    required this.onMove,
    required this.onEnd,
  });

  final String status;
  final List<Project> items;
  final ScrollController scroll;
  final bool dropOver;
  final String? dragging;
  final GlobalKey Function(String id) cardKey;
  final void Function(Project p, Offset global) onLift;
  final void Function(Offset global) onMove;
  final void Function(bool cancelled) onEnd;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final w = context.whirl;
    return AnimatedContainer(
      duration: Motion.fast,
      margin: const EdgeInsets.symmetric(horizontal: Space.s4),
      decoration: BoxDecoration(
        color: dropOver ? t.surfaceSunken : null,
        borderRadius: BorderRadius.circular(WhirlRadii.sm),
        border: Border.all(color: dropOver ? w.status(status) : const Color(0x00000000), width: 2),
      ),
      child: CustomScrollView(
        controller: scroll,
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.only(bottom: Space.s3),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(WhirlRadii.sm),
                border: Border.all(color: t.border),
              ),
              child: Column(
                children: [
                  // The status colour as a 4px top border (DESIGN.md §6.4).
                  Container(height: 4, color: w.status(status)),
                  Padding(
                    padding: const EdgeInsets.all(Space.s3),
                    child: Row(
                      children: [
                        Icon(statusIcon(status), size: 18),
                        const SizedBox(width: Space.s2),
                        Text(statusLabel[status]!, style: context.display(16, weight: FontWeight.w600)),
                        const Spacer(),
                        Text('${items.length}', style: context.mono(13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s6),
                child: Text(
                  'Nothing here.',
                  textAlign: TextAlign.center,
                  style: context.text.bodyLarge!.copyWith(color: t.textMuted),
                ),
              ),
            ),
          SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
            itemBuilder: (context, i) {
              final p = items[i];
              return KeyedSubtree(
                key: cardKey(p.id),
                child: LiftDetector(
                  onStart: (g) => onLift(p, g),
                  onMove: onMove,
                  onEnd: onEnd,
                  child: Opacity(
                    opacity: dragging == p.id ? 0.4 : 1,
                    child: IdeaCard(project: p, onTap: () => openIdea(context, p.id)),
                  ),
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Space.s6)),
        ],
      ),
    );
  }
}
