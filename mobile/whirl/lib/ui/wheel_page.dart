import 'dart:math' as math;

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../data/store.dart';
import '../data/text.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/wheel.dart';

/// Tests and screenshots seed the wheel's dice.
final wheelRandomProvider = Provider<math.Random?>((_) => null);

/// The Wheel (DESIGN.md §6.2): the wheel, what it spins from, and Spin and Filters.
class WheelPage extends ConsumerStatefulWidget {
  const WheelPage({super.key});

  @override
  ConsumerState<WheelPage> createState() => _WheelPageState();
}

class _WheelPageState extends ConsumerState<WheelPage> {
  bool _spinning = false;

  Future<void> _showResult(Project p) async {
    SemanticsService.sendAnnouncement(View.of(context), 'Picked ${p.name}', TextDirection.ltr);
    final again = await showKitSheet<bool>(context, builder: (_) => ResultSheet(project: p));
    if (again == true && mounted) ref.read(spinRequestProvider.notifier).request();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final pool = ref.watch(poolProvider);
    final filters = ref.watch(filtersProvider);
    final categories = ref.watch(storeProvider.select((d) => d.categories));
    final signal = ref.watch(spinRequestProvider);
    final haptics = ref.watch(hapticsProvider);

    return LayoutBuilder(
      builder: (context, box) {
        final size = math.min(math.min(box.maxWidth * 0.88, 520.0), box.maxHeight - 250).clamp(220.0, 520.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: Space.s4),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight - Space.s8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SpinWheel(
                        ideas: pool,
                        spinSignal: signal,
                        haptics: haptics,
                        random: ref.watch(wheelRandomProvider),
                        onSpinning: (s) => setState(() => _spinning = s),
                        onResult: _showResult,
                      ),
                      if (pool.isEmpty)
                        Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.all(size * 0.16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'No ideas match these filters',
                                  textAlign: TextAlign.center,
                                  style: context.text.bodyMedium!.copyWith(color: t.textMuted),
                                ),
                                if (filters.count > 0) ...[
                                  const SizedBox(height: Space.s3),
                                  KitButton(
                                    label: 'Clear filters',
                                    small: true,
                                    onPressed: ref.read(filtersProvider.notifier).clear,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s4),
                if (pool.isNotEmpty)
                  Text.rich(
                    TextSpan(
                      style: context.text.bodyLarge!.copyWith(color: t.textMuted),
                      children: [
                        const TextSpan(text: 'Spinning from '),
                        TextSpan(
                          text: '${pool.length}',
                          style: context.mono(16, color: t.text),
                        ),
                        TextSpan(text: pool.length == 1 ? ' idea' : ' ideas'),
                      ],
                    ),
                  ),
                const SizedBox(height: Space.s3),
                ActiveFilterChips(categories: categories),
                const SizedBox(height: Space.s4),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Space.s2,
                  runSpacing: Space.s2,
                  children: [
                    Opacity(
                      opacity: pool.isEmpty || _spinning ? 0.45 : 1,
                      child: CtaButton(
                        label: 'Spin',
                        height: 52,
                        onPressed: pool.isEmpty || _spinning ? null : ref.read(spinRequestProvider.notifier).request,
                      ),
                    ),
                    KitButton(
                      label: filters.count > 0 ? 'Filters ${filters.count}' : 'Filters',
                      icon: LucideIcons.slidersHorizontal,
                      onPressed: () => showKitSheet<void>(context, builder: (_) => const FilterSheet()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The pick (DESIGN.md §6.3): title, a few lines of description, categories, difficulty and dev
/// type, then Start building (to Doing) or Spin again. Pops true for Spin again.
class ResultSheet extends ConsumerWidget {
  const ResultSheet({super.key, required this.project});
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.kit;
    final p = ref.watch(storeProvider.select((d) => d.byId[project.id])) ?? project;
    final categories = ref.watch(storeProvider.select((d) => d.categories));
    final names = [
      for (final id in p.categoryIds)
        for (final c in categories)
          if (c.id == id) c.name,
    ];
    final summary = plainText(p.description);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Space.s5, Space.s5, Space.s5, Space.s4 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(p.name, style: context.display(40, height: 1.05))),
              IconButton(
                tooltip: 'Close',
                icon: Icon(LucideIcons.x, color: t.textMuted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: Space.s2),
            Text(
              summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodyLarge!.copyWith(color: t.textMuted),
            ),
          ],
          const SizedBox(height: Space.s3),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final n in names) Tag(n),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DifficultyDots(p.difficulty),
                  const SizedBox(width: Space.s2),
                  Text(p.difficulty, style: context.text.bodyMedium!.copyWith(color: t.textMuted)),
                ],
              ),
              Tag(p.devType),
            ],
          ),
          const SizedBox(height: Space.s5),
          Row(
            children: [
              Expanded(
                child: CtaButton(
                  label: 'Start building',
                  onPressed: () {
                    ref.read(storeProvider.notifier).moveProject(p, 'doing');
                    Navigator.of(context).pop();
                  },
                ),
              ),
              const SizedBox(width: Space.s2),
              KitButton(label: 'Spin again', onPressed: () => Navigator.of(context).pop(true)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every filter group as chips, for the Wheel (the chip row lives on the Backlog).
class FilterSheet extends ConsumerWidget {
  const FilterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(filtersProvider);
    final categories = ref.watch(storeProvider.select((d) => d.categories));
    final shown = ref.watch(poolProvider).length;
    return KitSheet(
      title: 'Filters',
      footer: Row(
        children: [
          Expanded(
            child: KitButton(
              label: 'Show ${plural(shown, 'idea')}',
              block: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (filters.count > 0) ...[
            const SizedBox(width: Space.s2),
            KitButton(
              label: 'Clear all',
              variant: ButtonVariant.ghost,
              onPressed: ref.read(filtersProvider.notifier).clear,
            ),
          ],
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (key, label, options) in filterGroups(categories))
            if (options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s4),
                child: KitField(
                  label: label,
                  child: Wrap(
                    spacing: Space.s2,
                    runSpacing: Space.s2,
                    children: [
                      for (final (v, text) in options)
                        ChoiceChip2(
                          label: text,
                          on: filters.group(key).contains(v),
                          onTap: () => ref.read(filtersProvider.notifier).toggle(key, v),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
