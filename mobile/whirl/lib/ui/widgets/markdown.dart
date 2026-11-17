import 'package:flutter/gestures.dart';
import 'package:kit/kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/text.dart';
import '../theme.dart';

/// The description preview (src/markdown.jsx): headings, lists, bold, italics, code and links.
/// Only web and mail links can be tapped.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.source, {super.key});
  final String? source;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

sealed class _Block {}

class _Para extends _Block {
  _Para(this.text);
  final String text;
}

class _Heading extends _Block {
  _Heading(this.text);
  final String text;
}

class _List extends _Block {
  final items = <String>[];
}

List<_Block> _parseBlocks(String source) {
  final blocks = <_Block>[];
  _List? list;
  for (final line in source.split('\n')) {
    final item = RegExp(r'^\s*[-*+]\s+(.*)').firstMatch(line);
    if (item != null) {
      if (list == null) {
        list = _List();
        blocks.add(list);
      }
      list.items.add(item[1]!);
      continue;
    }
    list = null;
    final heading = RegExp(r'^#{1,6}\s+(.*)').firstMatch(line);
    if (heading != null) {
      blocks.add(_Heading(heading[1]!));
    } else if (line.trim().isNotEmpty) {
      blocks.add(_Para(line));
    }
  }
  return blocks;
}

final _inline = RegExp(r'(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\))');

class _MarkdownViewState extends State<MarkdownView> {
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _taps) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _spans(String text, TextStyle base) {
    final t = context.kit;
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > at) out.add(TextSpan(text: text.substring(at, m.start)));
      final part = m[0]!;
      if (part.startsWith('**')) {
        out.add(
          TextSpan(
            text: part.substring(2, part.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700, fontVariations: [FontVariation.weight(700)]),
          ),
        );
      } else if (part.startsWith('`')) {
        out.add(
          TextSpan(
            text: part.substring(1, part.length - 1),
            style: context.mono((base.fontSize ?? 16) - 1, color: t.text).copyWith(backgroundColor: t.surfaceSunken),
          ),
        );
      } else if (part.startsWith('[')) {
        final link = RegExp(r'^\[(.+)\]\((.+)\)$').firstMatch(part)!;
        final href = safeUrl(link[2]!);
        if (href == null) {
          out.add(TextSpan(text: link[1]));
        } else {
          final r = TapGestureRecognizer()
            ..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
          _taps.add(r);
          out.add(
            TextSpan(
              text: link[1],
              recognizer: r,
              style: TextStyle(
                color: t.accentText,
                decoration: TextDecoration.underline,
                decorationColor: t.accentText,
              ),
            ),
          );
        }
      } else {
        out.add(
          TextSpan(
            text: part.substring(1, part.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      at = m.end;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
    final t = context.kit;
    final body = context.text.bodyLarge!;
    final blocks = _parseBlocks(widget.source ?? '');
    if (blocks.isEmpty) {
      return Text('Nothing to preview yet.', style: body.copyWith(color: t.textMuted));
    }
    Widget rich(String text, TextStyle style) => Text.rich(TextSpan(style: style, children: _spans(text, style)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, b) in blocks.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : Space.s2),
            child: switch (b) {
              _Heading(:final text) => rich(text, context.display(17, weight: FontWeight.w600)),
              _Para(:final text) => rich(text, body),
              _List(:final items) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 18,
                            child: Text('•', style: body.copyWith(color: t.textMuted)),
                          ),
                          Expanded(child: rich(item, body)),
                        ],
                      ),
                    ),
                ],
              ),
            },
          ),
      ],
    );
  }
}
