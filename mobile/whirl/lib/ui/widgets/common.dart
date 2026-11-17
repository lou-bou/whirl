import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/model.dart';
import '../state.dart';
import '../theme.dart';

/// Each status has an icon as well as a colour, so it is never colour alone (DESIGN.md §3).
IconData statusIcon(String status) => switch (status) {
  'doing' => LucideIcons.hammer,
  'completed' => LucideIcons.circleCheck,
  _ => LucideIcons.lightbulb,
};

String plural(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';

/// Status fill, ink text and icon.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final w = context.whirl;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Motion.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: Space.s2, vertical: 2),
      decoration: BoxDecoration(color: w.status(status), borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon(status), size: 14, color: w.onStatus),
          const SizedBox(width: Space.s1),
          Text(
            statusLabel[status]!,
            style: context.text.labelMedium!.copyWith(color: w.onStatus, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Filled dots for the difficulty: one for Easy up to four for Expert.
class DifficultyDots extends StatelessWidget {
  const DifficultyDots(this.level, {super.key});
  final String level;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final filled = difficulties.indexOf(level) + 1;
    return Semantics(
      label: 'Difficulty: $level',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < difficulties.length; i++)
            Container(
              width: 7,
              height: 7,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? t.text : null,
                border: Border.all(color: i < filled ? t.text : t.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// A neutral chip on a card: categories, dev type, content. Only status gets colour.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.dashed = false});
  final String label;

  /// "Saved on this device".
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s2, vertical: 2),
      decoration: BoxDecoration(
        color: dashed ? null : t.surfaceSunken,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: dashed ? Border.all(color: t.border) : null,
      ),
      child: Text(label, style: context.text.labelMedium!.copyWith(fontSize: 12)),
    );
  }
}

/// A filter chip: inverted when on.
class ChoiceChip2 extends StatelessWidget {
  const ChoiceChip2({super.key, required this.label, required this.on, required this.onTap, this.trailing});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.fast,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: Space.s3),
          decoration: BoxDecoration(
            color: on ? t.text : t.surfaceSunken,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.text.bodyMedium!.copyWith(
                  color: on ? t.bg : t.text,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Space.s1),
                Icon(trailing, size: 14, color: on ? t.bg : t.text),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The filter groups (src/App.jsx filterGroups): key, label, and (value, text) options.
List<(String, String, List<(String, String)>)> filterGroups(List<Category> categories) => [
  ('category', 'Category', [for (final c in categories) (c.name, c.name)]),
  ('difficulty', 'Difficulty', [for (final d in difficulties) (d, d)]),
  ('devType', 'Dev type', [for (final d in devTypes) (d, d)]),
  ('status', 'Status', [for (final s in statuses) (s, statusLabel[s]!)]),
  ('content', 'Content', const [('Made', 'Content made'), ('Not made', 'No content')]),
];

/// The filters that are on, as chips that remove themselves.
class ActiveFilterChips extends ConsumerWidget {
  const ActiveFilterChips({super.key, required this.categories});
  final List<Category> categories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(filtersProvider);
    final active = [
      for (final (key, _, options) in filterGroups(categories))
        for (final (v, text) in options)
          if (filters.group(key).contains(v)) (key, v, text),
    ];
    if (active.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Space.s2,
      runSpacing: Space.s2,
      alignment: WrapAlignment.center,
      children: [
        for (final (key, v, text) in active)
          ChoiceChip2(
            label: text,
            on: true,
            trailing: LucideIcons.x,
            onTap: () => ref.read(filtersProvider.notifier).toggle(key, v),
          ),
      ],
    );
  }
}

/// A full-width strip under the header: the expired token, or changes the server refused.
class Strip extends StatelessWidget {
  const Strip({super.key, required this.text, this.danger = false, this.action, this.onAction});
  final String text;
  final bool danger;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final color = danger ? t.negative : t.text;
    return Semantics(
      liveRegion: true,
      child: Container(
        color: t.surfaceSunken,
        padding: const EdgeInsets.fromLTRB(Space.s4, Space.s2, Space.s2, Space.s2),
        child: Row(
          children: [
            if (danger) ...[Icon(LucideIcons.circleAlert, size: 18, color: color), const SizedBox(width: Space.s2)],
            Expanded(
              child: Text(text, style: context.text.bodyMedium!.copyWith(color: color)),
            ),
            if (action != null) KitButton(label: action!, small: true, onPressed: onAction),
          ],
        ),
      ),
    );
  }
}

/// The coral call to action (Spin, Start building), with the floating shadow light mode allows.
class CtaButton extends StatelessWidget {
  const CtaButton({super.key, required this.label, this.icon, this.onPressed, this.height = 52, this.floating = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final w = context.whirl;
    return Pressable(
      onTap: onPressed,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: Space.s6),
        decoration: BoxDecoration(
          color: w.cta,
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: floating ? w.floatShadow : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 20, color: w.onStatus), const SizedBox(width: Space.s2)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.labelLarge!.copyWith(color: w.onStatus, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A screen title in the display font.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(header: true, child: Text(text, style: context.display(28)));
}
