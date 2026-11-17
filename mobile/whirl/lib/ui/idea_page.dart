import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kit/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/store.dart';
import '../data/text.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/markdown.dart';

/// An idea, or a new one when [id] is null (DESIGN.md §6.5): title, description in Markdown with
/// Write and Preview, categories, difficulty, dev type, status, content, links and notes.
class IdeaPage extends ConsumerStatefulWidget {
  const IdeaPage({super.key, required this.id});
  final String? id;

  @override
  ConsumerState<IdeaPage> createState() => _IdeaPageState();
}

class _IdeaPageState extends ConsumerState<IdeaPage> {
  late final Project? _original = widget.id == null ? null : ref.read(storeProvider).byId[widget.id];
  late final _name = TextEditingController(text: _original?.name ?? '');
  late final _description = TextEditingController(text: _original?.description ?? '');
  late final _links = TextEditingController(text: _original?.link ?? '');
  late final _notes = TextEditingController(text: _original?.notes ?? '');
  late String _difficulty = _original?.difficulty ?? 'Medium';
  late String _devType = _original?.devType ?? 'Assisted';
  late String _status = _original?.status ?? 'idea';
  late bool _hasContent = _original?.hasContent ?? false;
  late List<String> _categoryIds = [...?_original?.categoryIds];
  bool _preview = false;

  bool get _isNew => _original == null;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _description, _links, _notes]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _description, _links, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Json get _fields => {
    'name': _name.text.trim(),
    'description': _description.text,
    'difficulty': _difficulty,
    'dev_type': _devType,
    'status': _status,
    'link': _links.text.trim().isEmpty ? null : _links.text.trim(),
    'has_content': _hasContent,
    'notes': _notes.text,
  };

  bool get _dirty {
    final o = _original;
    if (o == null) {
      return _name.text.trim().isNotEmpty ||
          _description.text.isNotEmpty ||
          _links.text.isNotEmpty ||
          _notes.text.isNotEmpty;
    }
    String s(String? v) => v ?? '';
    return _name.text.trim() != o.name ||
        _description.text != s(o.description) ||
        _links.text.trim() != s(o.link).trim() ||
        _notes.text != s(o.notes) ||
        _difficulty != o.difficulty ||
        _devType != o.devType ||
        _status != o.status ||
        _hasContent != o.hasContent ||
        _categoryIds.toSet().difference(o.categoryIds.toSet()).isNotEmpty ||
        o.categoryIds.toSet().difference(_categoryIds.toSet()).isNotEmpty;
  }

  void _save() {
    if (_name.text.trim().isEmpty) return;
    final store = ref.read(storeProvider.notifier);
    if (_isNew) {
      store.createProject(_fields, _categoryIds);
    } else {
      // Compared with what the phone shows now, so only real changes are sent.
      final before = ref.read(storeProvider).byId[_original!.id] ?? _original;
      store.updateProject(before, _fields, _categoryIds);
      if (_status == 'completed' && before.status != 'completed' && !MediaQuery.disableAnimationsOf(context)) {
        ref.read(burstProvider.notifier).celebrate(before.id);
      }
    }
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await confirmSheet(context, title: 'Delete this idea?', confirmLabel: 'Delete', danger: true);
    if (!ok || !mounted) return;
    final p = ref.read(storeProvider).byId[_original!.id] ?? _original;
    ref.read(storeProvider.notifier).deleteProject(p);
    Navigator.of(context).pop();
  }

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await confirmSheet(
      context,
      title: 'Discard changes?',
      message: 'Your edits to this idea will be lost.',
      confirmLabel: 'Discard',
      danger: true,
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.kit;
    final categories = ref.watch(storeProvider.select((d) => d.categories));
    final links = splitLinks(_links.text);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    Widget seg<T>(String label, T value, List<(T, String)> options, ValueChanged<T> set) => KitField(
      label: label,
      child: KitSegmented<T>(
        value: value,
        options: [for (final (v, text) in options) SegOption(v, text)],
        onChanged: (v) => setState(() => set(v)),
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: t.surface,
        appBar: AppBar(
          backgroundColor: t.surface,
          leading: IconButton(tooltip: 'Back', icon: const Icon(LucideIcons.arrowLeft), onPressed: _leave),
          title: Text(_isNew ? 'New idea' : 'Edit idea'),
          actions: [
            if (!_isNew)
              IconButton(
                tooltip: 'Delete idea',
                icon: Icon(LucideIcons.trash2, color: t.negative),
                onPressed: _delete,
              ),
            const SizedBox(width: Space.s1),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: t.border),
          ),
        ),
        body: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(Space.s4),
          children: [
            KitField(
              label: 'Title',
              child: TextField(
                controller: _name,
                autofocus: _isNew,
                textCapitalization: TextCapitalization.sentences,
                style: context.text.bodyLarge,
              ),
            ),
            const SizedBox(height: Space.s4),
            Row(
              children: [
                Text('Description', style: context.text.labelMedium!.copyWith(fontSize: 13)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    setState(() => _preview = !_preview);
                  },
                  child: Text(
                    _preview ? 'Write' : 'Preview',
                    style: context.text.labelLarge!.copyWith(color: t.accentText),
                  ),
                ),
              ],
            ),
            if (_preview)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 100),
                padding: const EdgeInsets.all(Space.s3),
                decoration: BoxDecoration(
                  border: Border.all(color: t.border),
                  borderRadius: BorderRadius.circular(WhirlRadii.sm),
                ),
                child: MarkdownView(_description.text),
              )
            else
              TextField(
                controller: _description,
                minLines: 4,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Markdown works here'),
              ),
            const SizedBox(height: Space.s4),
            KitField(
              label: 'Categories',
              child: categories.isEmpty
                  ? Text('Add categories in Settings.', style: context.text.bodyMedium!.copyWith(color: t.textMuted))
                  : Wrap(
                      spacing: Space.s2,
                      runSpacing: Space.s2,
                      children: [
                        for (final c in categories)
                          ChoiceChip2(
                            label: c.name,
                            on: _categoryIds.contains(c.id),
                            onTap: () => setState(() {
                              _categoryIds = _categoryIds.contains(c.id)
                                  ? [
                                      for (final x in _categoryIds)
                                        if (x != c.id) x,
                                    ]
                                  : [..._categoryIds, c.id];
                            }),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: Space.s4),
            seg('Difficulty', _difficulty, [for (final d in difficulties) (d, d)], (v) => _difficulty = v),
            const SizedBox(height: Space.s4),
            seg('Dev type', _devType, [for (final d in devTypes) (d, d)], (v) => _devType = v),
            const SizedBox(height: Space.s4),
            seg('Status', _status, [for (final s in statuses) (s, statusLabel[s]!)], (v) => _status = v),
            const SizedBox(height: Space.s4),
            seg('Content', _hasContent, const [(true, 'Content made'), (false, 'No content')], (v) => _hasContent = v),
            const SizedBox(height: Space.s4),
            KitField(
              label: 'Links',
              child: TextField(
                controller: _links,
                minLines: 2,
                maxLines: null,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(hintText: 'One link per line'),
              ),
            ),
            for (final l in links)
              if (safeUrl(l) != null)
                Pressable(
                  onTap: () => launchUrl(Uri.parse(safeUrl(l)!), mode: LaunchMode.externalApplication),
                  semanticLabel: 'Open $l',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s2),
                    child: Row(
                      children: [
                        Icon(LucideIcons.externalLink, size: 16, color: t.accentText),
                        const SizedBox(width: Space.s2),
                        Expanded(
                          child: Text(
                            l,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodyMedium!.copyWith(color: t.accentText),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: Space.s4),
            KitField(
              label: 'Notes',
              child: TextField(
                controller: _notes,
                minLines: 4,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
              ),
            ),
            if (!_isNew && formatDateTime(_original!.createdAt).isNotEmpty) ...[
              const SizedBox(height: Space.s5),
              Text(
                'Created ${formatDateTime(_original.createdAt)}'
                '${formatDateTime(_original.updatedAt).isEmpty ? '' : ' · Updated ${formatDateTime(_original.updatedAt)}'}',
                style: context.mono(12),
              ),
            ],
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: t.surface,
            border: Border(top: BorderSide(color: t.border)),
          ),
          padding: EdgeInsets.fromLTRB(Space.s4, Space.s3, Space.s4, Space.s3 + (keyboard ? 0 : bottom)),
          child: Row(
            children: [
              Expanded(
                child: KitButton(
                  label: 'Save',
                  block: true,
                  variant: ButtonVariant.secondary,
                  onPressed: _name.text.trim().isEmpty ? null : _save,
                ),
              ),
              const SizedBox(width: Space.s2),
              KitButton(label: 'Cancel', variant: ButtonVariant.ghost, onPressed: _leave),
            ],
          ),
        ),
      ),
    );
  }
}
