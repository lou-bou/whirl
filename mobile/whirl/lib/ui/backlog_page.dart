import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../data/store.dart';
import '../data/sync.dart';
import 'idea_page.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/idea_card.dart';

/// Asks for a spin from anywhere: to the Wheel, and spin.
void requestSpin(WidgetRef ref) {
  ref.read(tabProvider.notifier).go(wheelTab);
  ref.read(spinRequestProvider.notifier).request();
}

/// Home: search, the filter chips, the list, and the floating Spin button (DESIGN.md §6.1).
class BacklogPage extends ConsumerStatefulWidget {
  const BacklogPage({super.key});

  @override
  ConsumerState<BacklogPage> createState() => _BacklogPageState();
}

class _BacklogPageState extends ConsumerState<BacklogPage> {
  late final _search = TextEditingController(text: ref.read(searchProvider));

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final data = ref.watch(storeProvider);
    final ideas = ref.watch(backlogProvider);
    final filters = ref.watch(filtersProvider);
    final poolEmpty = ref.watch(poolProvider.select((p) => p.isEmpty));
    final total = data.projects.length;
    return Stack(
      children: [
        RefreshIndicator(
          color: t.text,
          backgroundColor: t.surface,
          onRefresh: () => ref.read(syncProvider.notifier).sync(),
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.s4, Space.s3, Space.s4, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: ref.read(searchProvider.notifier).set,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Search ideas',
                            prefixIcon: Icon(LucideIcons.search, size: 18, color: t.textMuted),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    icon: Icon(LucideIcons.x, size: 18, color: t.textMuted),
                                    onPressed: () {
                                      _search.clear();
                                      ref.read(searchProvider.notifier).set('');
                                      setState(() {});
                                    },
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.s2),
                      KitButton(label: 'New idea', icon: LucideIcons.plus, onPressed: () => openIdea(context, null)),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _FilterRow(categories: data.categories)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Space.s4, Space.s3, Space.s2, Space.s2),
                  child: SizedBox(
                    height: 32,
                    child: Row(
                      children: [
                        Text('${ideas.length} of $total', style: context.mono(13)),
                        const Spacer(),
                        if (filters.count > 0)
                          TextButton(
                            onPressed: ref.read(filtersProvider.notifier).clear,
                            child: Text('Clear all', style: context.text.labelLarge!.copyWith(color: t.accentText)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (ideas.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: Space.s8),
                    child: Text(
                      !data.loaded && total == 0
                          ? 'Loading your ideas…'
                          : (total > 0 ? 'No ideas match. Try fewer filters.' : 'No ideas yet. Add your first one.'),
                      textAlign: TextAlign.center,
                      style: context.text.bodyLarge!.copyWith(color: t.textMuted),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(Space.s4, 0, Space.s4, 96),
                sliver: SliverList.separated(
                  itemCount: ideas.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Space.s2),
                  itemBuilder: (context, i) => IdeaCard(
                    key: ValueKey(ideas[i].id),
                    project: ideas[i],
                    onTap: () => openIdea(context, ideas[i].id),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: Space.s4,
          bottom: Space.s4,
          child: Opacity(
            opacity: poolEmpty ? 0.45 : 1,
            child: CtaButton(
              label: 'Spin',
              icon: LucideIcons.rotateCw,
              height: 56,
              floating: true,
              onPressed: poolEmpty ? null : () => requestSpin(ref),
            ),
          ),
        ),
      ],
    );
  }
}

/// The filter chips in one sideways row, groups split by a hairline; the edges fade only while
/// there is more to see that way.
class _FilterRow extends ConsumerStatefulWidget {
  const _FilterRow({required this.categories});
  final List<Category> categories;

  @override
  ConsumerState<_FilterRow> createState() => _FilterRowState();
}

class _FilterRowState extends ConsumerState<_FilterRow> {
  final _scroll = ScrollController();
  bool _fadeStart = false, _fadeEnd = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  void _update() {
    if (!_scroll.hasClients || !mounted) return;
    final p = _scroll.position;
    final start = p.pixels > 4, end = p.pixels < p.maxScrollExtent - 4;
    if (start != _fadeStart || end != _fadeEnd) {
      setState(() {
        _fadeStart = start;
        _fadeEnd = end;
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final filters = ref.watch(filtersProvider);
    final groups = filterGroups(widget.categories);
    final row = SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Space.s4),
      child: Row(
        children: [
          for (final (g, (key, label, options)) in groups.indexed) ...[
            if (g > 0 && options.isNotEmpty)
              Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: Space.s2),
                color: t.border,
              ),
            for (final (i, (v, text)) in options.indexed)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : Space.s2),
                child: Semantics(
                  label: '$label: $text',
                  excludeSemantics: true,
                  selected: filters.group(key).contains(v),
                  button: true,
                  child: ChoiceChip2(
                    label: text,
                    on: filters.group(key).contains(v),
                    onTap: () => ref.read(filtersProvider.notifier).toggle(key, v),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Space.s3),
      child: SizedBox(
        height: 36,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _update());
            return false;
          },
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => LinearGradient(
              colors: [
                _fadeStart ? t.bg.withValues(alpha: 0) : t.bg,
                t.bg,
                t.bg,
                _fadeEnd ? t.bg.withValues(alpha: 0) : t.bg,
              ],
              stops: [0, 40 / r.width, 1 - 40 / r.width, 1],
            ).createShader(r),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// Opens an idea, or a new one when [id] is null.
void openIdea(BuildContext context, String? id) {
  HapticFeedback.selectionClick();
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IdeaPage(id: id))));
}
