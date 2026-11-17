import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../data/api.dart';
import '../data/store.dart';
import '../data/sync.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Settings: theme and spin haptics (this phone only), categories (they need the server), the
/// connection, and what is waiting to be sent.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.kit;
    final prefs = ref.read(prefsProvider.notifier);
    final theme = ref.watch(prefProvider(themeModePref)) ?? 'system';
    final haptics = ref.watch(hapticsProvider);
    final connection = ref.watch(connectionProvider);
    final queued = ref.watch(storeProvider.select((d) => d.queue.length));
    final sync = ref.watch(syncProvider);

    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: Space.s4),
      child: Container(
        padding: const EdgeInsets.all(Space.s4),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(WhirlRadii.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: context.display(18, weight: FontWeight.w600)),
            const SizedBox(height: Space.s3),
            ...children,
          ],
        ),
      ),
    );

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(Space.s4, Space.s4, Space.s4, Space.s8),
      children: [
        const ScreenTitle('Settings'),
        const SizedBox(height: Space.s4),
        section('Appearance', [
          KitSegmented<String>(
            value: theme,
            options: const [SegOption('system', 'System'), SegOption('light', 'Light'), SegOption('dark', 'Dark')],
            onChanged: (v) => prefs.set(themeModePref, v),
          ),
        ]),
        section('Spin', [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Vibrate while the wheel spins', style: context.text.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      'A tick at each slice and a bump when it lands.',
                      style: context.text.bodyMedium!.copyWith(color: t.textMuted),
                    ),
                  ],
                ),
              ),
              Switch(
                value: haptics,
                activeThumbColor: t.onAccent,
                activeTrackColor: t.accent,
                onChanged: (on) => prefs.set(hapticsPref, on ? 'on' : 'off'),
              ),
            ],
          ),
        ]),
        section('Categories', const [_Categories()]),
        section('Connection', [
          Pressable(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConnectionScreen(
                  appName: 'Whirl',
                  healthPath: WhirlApi.healthPath,
                  isHealthy: WhirlApi.isHealthy,
                  onSaved: () {
                    Navigator.of(context).pop();
                    unawaited(ref.read(syncProvider.notifier).sync());
                  },
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.server, size: 20, color: t.textMuted),
                const SizedBox(width: Space.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Uri.tryParse(connection?.baseUrl ?? '')?.host ?? '', style: context.text.bodyLarge),
                      Text(switch (sync.state) {
                        SyncState.accessDenied => 'Access refused the service token',
                        SyncState.offline => queued > 0 ? 'Offline · ${plural(queued, 'change')} waiting' : 'Offline',
                        _ => queued > 0 ? 'Sending ${plural(queued, 'change')}…' : 'All changes saved',
                      }, style: context.text.bodyMedium!.copyWith(color: t.textMuted)),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 18, color: t.textMuted),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

/// Add, rename and delete categories. They go straight to the server: queued ideas can point at
/// categories, so changing them offline could break those links (src/App.jsx).
class _Categories extends ConsumerStatefulWidget {
  const _Categories();

  @override
  ConsumerState<_Categories> createState() => _CategoriesState();
}

class _CategoriesState extends ConsumerState<_Categories> {
  final _new = TextEditingController();
  final _renaming = TextEditingController();
  String? _editing;
  bool _busy = false;

  @override
  void dispose() {
    _new.dispose();
    _renaming.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(WhirlApi api) action) async {
    setState(() => _busy = true);
    try {
      await action(ref.read(whirlApiProvider));
    } on ApiException catch (e) {
      if (isRefusal(e) || e.kind == ApiFailure.http) {
        ref.read(noticeProvider.notifier).show(e.message);
      } else {
        ref.read(syncProvider.notifier).report(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await ref.read(syncProvider.notifier).sync();
  }

  void _add() {
    final name = _new.text.trim();
    if (name.isEmpty) return;
    _new.clear();
    unawaited(_run((api) => api.addCategory(name)));
  }

  void _rename(Category c, String name) {
    setState(() => _editing = null);
    final n = name.trim();
    if (n.isEmpty || n == c.name) return;
    unawaited(_run((api) => api.renameCategory(c.id, n)));
  }

  Future<void> _delete(Category c) async {
    final ok = await confirmSheet(
      context,
      title: 'Remove this category?',
      message: "Ideas won't be deleted.",
      confirmLabel: 'Remove',
      danger: true,
    );
    if (ok) await _run((api) => api.deleteCategory(c.id));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final data = ref.watch(storeProvider);
    final online = ref.watch(syncProvider.select((s) => s.online)) && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!ref.watch(syncProvider.select((s) => s.online))) ...[
          Text(
            'Category changes need a connection. You can still look at them here.',
            style: context.text.bodyMedium!.copyWith(color: t.textMuted),
          ),
          const SizedBox(height: Space.s3),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _new,
                enabled: online,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _add(),
                decoration: const InputDecoration(hintText: 'New category'),
              ),
            ),
            const SizedBox(width: Space.s2),
            KitButton(label: 'Add', onPressed: online ? _add : null),
          ],
        ),
        const SizedBox(height: Space.s2),
        if (data.categories.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s3),
            child: Text('No categories yet.', style: context.text.bodyMedium!.copyWith(color: t.textMuted)),
          ),
        for (final c in data.categories)
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: _editing == c.id
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s1),
                    child: Focus(
                      // Leaving the field saves it, like the web app's.
                      onFocusChange: (has) {
                        if (!has && _editing == c.id) _rename(c, _renaming.text);
                      },
                      child: TextField(
                        autofocus: true,
                        controller: _renaming,
                        textCapitalization: TextCapitalization.sentences,
                        onSubmitted: (v) => _rename(c, v),
                        decoration: InputDecoration(hintText: 'Rename ${c.name}'),
                      ),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Pressable(
                          semanticLabel: 'Rename ${c.name}',
                          onTap: online
                              ? () => setState(() {
                                  _renaming.text = c.name;
                                  _editing = c.id;
                                })
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: Space.s3),
                            child: Row(
                              children: [
                                Flexible(child: Text(c.name, style: context.text.bodyLarge)),
                                const SizedBox(width: Space.s2),
                                Text(
                                  '${data.projects.where((p) => p.categoryIds.contains(c.id)).length}',
                                  style: context.mono(12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (online)
                        IconButton(
                          tooltip: 'Delete ${c.name}',
                          icon: Icon(LucideIcons.trash2, size: 18, color: t.negative),
                          onPressed: () => _delete(c),
                        ),
                    ],
                  ),
          ),
      ],
    );
  }
}
