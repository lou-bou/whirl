import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/store.dart';
import '../../data/text.dart';
import '../state.dart';
import '../theme.dart';
import 'common.dart';

/// The idea card (DESIGN.md §6): a 4px bar and pill in the status colour, the title, one plain
/// line of description, then categories, dev type, content, difficulty dots and the age.
class IdeaCard extends ConsumerWidget {
  const IdeaCard({super.key, required this.project, this.onTap, this.lifted = false});
  final Project project;
  final VoidCallback? onTap;

  /// The copy under the finger while dragging on the Board.
  final bool lifted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.kit;
    final w = context.whirl;
    final p = project;
    final categories = ref.watch(storeProvider.select((d) => d.categories));
    final names = [
      for (final id in p.categoryIds)
        for (final c in categories)
          if (c.id == id) c.name,
    ];
    final unsent = ref.watch(unsentProvider.select((s) => s.contains(p.id)));
    final burst = ref.watch(burstProvider.select((b) => b == p.id));
    final now = ref.watch(nowProvider);
    final summary = plainText(p.description);

    final card = Container(
      constraints: const BoxConstraints(minHeight: 72),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(WhirlRadii.md),
        border: Border.all(color: t.border),
        boxShadow: lifted ? w.floatShadow : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedContainer(duration: const Duration(milliseconds: 220), width: 4, color: w.status(p.status)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.s4, Space.s3, Space.s4, Space.s3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            p.name,
                            style: context.display(20, weight: FontWeight.w600).copyWith(letterSpacing: -0.2),
                          ),
                        ),
                        const SizedBox(width: Space.s2),
                        Padding(padding: const EdgeInsets.only(top: 2), child: StatusChip(p.status)),
                      ],
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: Space.s1),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodyMedium!.copyWith(color: t.textMuted),
                      ),
                    ],
                    const SizedBox(height: Space.s2),
                    Wrap(
                      spacing: Space.s2,
                      runSpacing: Space.s1,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final n in names) Tag(n),
                        Tag(p.devType),
                        if (p.hasContent) const Tag('Content made'),
                        if (unsent) const Tag('Saved on this device', dashed: true),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DifficultyDots(p.difficulty),
                            const SizedBox(width: Space.s2),
                            Text('updated ${relativeAge(p.updatedAt, now)}', style: context.mono(12)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final body = Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        if (burst && !MediaQuery.disableAnimationsOf(context)) const Positioned.fill(child: _Burst()),
      ],
    );
    if (onTap == null) return body;
    return Pressable(onTap: onTap, semanticLabel: '${p.name}, ${statusLabel[p.status]}', child: body);
  }
}

/// The one allowed celebration: a teal ring that grows and fades off a completed card.
class _Burst extends StatelessWidget {
  const _Burst();

  @override
  Widget build(BuildContext context) {
    final teal = context.whirl.completed;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Motion.easeOut,
        builder: (context, v, _) => Transform.scale(
          scale: 1 + 0.06 * v,
          child: Opacity(
            opacity: 1 - v,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(WhirlRadii.md),
                border: Border.all(color: teal, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
