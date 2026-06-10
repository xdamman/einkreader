import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Renders Markdown as Flutter widgets with full control over text spans so
/// saved highlights can be painted inline. Supports the subset produced by
/// html2md: headings, paragraphs, lists, blockquotes, code, images, links,
/// bold/italic and horizontal rules.
class MarkdownView extends StatefulWidget {
  final String markdown;

  /// Saved highlight strings; occurrences are painted with a grey wash.
  final List<String> highlights;
  final double fontSize;

  const MarkdownView({
    super.key,
    required this.markdown,
    this.highlights = const [],
    this.fontSize = 18,
  });

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.highlights != widget.highlights) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers.clear();
    }
  }

  TextStyle get _bodyStyle => TextStyle(
        color: Colors.black,
        fontSize: widget.fontSize,
        height: 1.55,
        fontFamily: readingFontFamily,
        fontFamilyFallback: readingFontFallback,
      );

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(widget.markdown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final block in blocks) _buildBlock(block)],
    );
  }

  // ------------------------------------------------------------ block model

  Widget _buildBlock(_Block block) {
    switch (block.type) {
      case _BlockType.heading:
        final size = switch (block.level) {
          1 => widget.fontSize + 10,
          2 => widget.fontSize + 6,
          3 => widget.fontSize + 3,
          _ => widget.fontSize + 1,
        };
        return Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text.rich(
            TextSpan(
                children: _inlineSpans(block.text,
                    _bodyStyle.copyWith(
                        fontSize: size, fontWeight: FontWeight.w700))),
          ),
        );
      case _BlockType.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text.rich(
              TextSpan(children: _inlineSpans(block.text, _bodyStyle))),
        );
      case _BlockType.quote:
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.fromLTRB(14, 4, 0, 4),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Colors.black, width: 3)),
          ),
          child: Text.rich(
            TextSpan(
                children: _inlineSpans(
                    block.text, _bodyStyle.copyWith(fontStyle: FontStyle.italic))),
          ),
        );
      case _BlockType.listItem:
        return Padding(
          padding: EdgeInsets.only(
              left: 8.0 + block.level * 18, bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: Text(block.marker ?? '•', style: _bodyStyle),
              ),
              Expanded(
                child: Text.rich(
                    TextSpan(children: _inlineSpans(block.text, _bodyStyle))),
              ),
            ],
          ),
        );
      case _BlockType.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(width: 1)),
          child: Text(
            block.text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: widget.fontSize - 3,
              height: 1.4,
              color: Colors.black,
            ),
          ),
        );
      case _BlockType.image:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            children: [
              Image.network(
                block.url ?? '',
                // Offline or broken images degrade to their caption.
                errorBuilder: (_, __, ___) => block.text.isEmpty
                    ? const SizedBox.shrink()
                    : Text('[image: ${block.text}]',
                        style: _bodyStyle.copyWith(
                            fontStyle: FontStyle.italic,
                            fontSize: widget.fontSize - 3)),
              ),
              if (block.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(block.text,
                      style: _bodyStyle.copyWith(
                          fontSize: widget.fontSize - 4,
                          fontStyle: FontStyle.italic)),
                ),
            ],
          ),
        );
      case _BlockType.rule:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(),
        );
    }
  }

  static final _imageOnly =
      RegExp(r'^!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)$');
  static final _listLine = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
  static final _headingLine = RegExp(r'^(#{1,6})\s+(.*)$');

  List<_Block> _parseBlocks(String markdown) {
    final blocks = <_Block>[];
    final lines = markdown.split('\n');
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      final text = paragraph.join(' ').trim();
      if (text.isNotEmpty) blocks.add(_Block(_BlockType.paragraph, text));
      paragraph.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.startsWith('```')) {
        flushParagraph();
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          code.add(lines[i]);
          i++;
        }
        blocks.add(_Block(_BlockType.code, code.join('\n')));
        continue;
      }

      if (trimmed.isEmpty) {
        flushParagraph();
        continue;
      }

      final heading = _headingLine.firstMatch(trimmed);
      if (heading != null) {
        flushParagraph();
        blocks.add(_Block(_BlockType.heading, heading.group(2)!,
            level: heading.group(1)!.length));
        continue;
      }

      if (RegExp(r'^(\-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        flushParagraph();
        blocks.add(_Block(_BlockType.rule, ''));
        continue;
      }

      final image = _imageOnly.firstMatch(trimmed);
      if (image != null) {
        flushParagraph();
        blocks.add(_Block(_BlockType.image, image.group(1) ?? '',
            url: image.group(2)));
        continue;
      }

      if (trimmed.startsWith('>')) {
        flushParagraph();
        final quote = <String>[trimmed.replaceFirst(RegExp(r'^>\s?'), '')];
        while (i + 1 < lines.length && lines[i + 1].trim().startsWith('>')) {
          i++;
          quote.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        }
        blocks.add(_Block(_BlockType.quote, quote.join(' ').trim()));
        continue;
      }

      final list = _listLine.firstMatch(line);
      if (list != null) {
        flushParagraph();
        final indent = list.group(1)!.length ~/ 2;
        final marker = list.group(2)!;
        blocks.add(_Block(_BlockType.listItem, list.group(3)!,
            level: indent > 3 ? 3 : indent,
            marker: RegExp(r'^\d').hasMatch(marker) ? marker : '•'));
        continue;
      }

      paragraph.add(trimmed);
    }
    flushParagraph();
    return blocks;
  }

  // ---------------------------------------------------------- inline spans

  static final _inlinePattern = RegExp(
      r'\*\*(.+?)\*\*|__(.+?)__|\*([^*\s][^*]*?)\*|_([^_\s][^_]*?)_|'
      r'`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|'
      r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)');

  List<InlineSpan> _inlineSpans(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _inlinePattern.allMatches(text)) {
      if (match.start > index) {
        spans.addAll(
            _highlighted(text.substring(index, match.start), style));
      }
      if (match.group(1) != null || match.group(2) != null) {
        spans.addAll(_highlighted(match.group(1) ?? match.group(2)!,
            style.copyWith(fontWeight: FontWeight.w700)));
      } else if (match.group(3) != null || match.group(4) != null) {
        spans.addAll(_highlighted(match.group(3) ?? match.group(4)!,
            style.copyWith(fontStyle: FontStyle.italic)));
      } else if (match.group(5) != null) {
        spans.addAll(_highlighted(
            match.group(5)!,
            style.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const [],
                backgroundColor: const Color(0xFFEEEEEE))));
      } else if (match.group(6) != null) {
        final url = match.group(7)!;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication);
        _recognizers.add(recognizer);
        spans.addAll(_highlighted(
            match.group(6)!,
            style.copyWith(decoration: TextDecoration.underline),
            recognizer: recognizer));
      } else if (match.group(8) != null) {
        // Inline image: render as caption text only.
        final alt = match.group(8)!;
        if (alt.isNotEmpty) {
          spans.addAll(_highlighted(
              '[image: $alt]', style.copyWith(fontStyle: FontStyle.italic)));
        }
      }
      index = match.end;
    }
    if (index < text.length) {
      spans.addAll(_highlighted(text.substring(index), style));
    }
    return spans;
  }

  /// Highlights may span several blocks; selections are stored with
  /// newlines, so match each line separately.
  Iterable<String> get _highlightNeedles sync* {
    for (final highlight in widget.highlights) {
      for (final line in highlight.split('\n')) {
        final needle = line.trim();
        if (needle.length > 2) yield needle;
      }
    }
  }

  /// Splits [text] so every saved highlight occurrence gets a grey wash.
  List<InlineSpan> _highlighted(String text, TextStyle style,
      {TapGestureRecognizer? recognizer}) {
    final ranges = <(int, int)>[];
    for (final needle in _highlightNeedles) {
      var from = 0;
      while (true) {
        final at = text.indexOf(needle, from);
        if (at == -1) break;
        ranges.add((at, at + needle.length));
        from = at + needle.length;
      }
    }
    if (ranges.isEmpty) {
      return [TextSpan(text: text, style: style, recognizer: recognizer)];
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    // Merge overlapping ranges.
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2));
      } else {
        merged.add(range);
      }
    }
    final spans = <InlineSpan>[];
    var index = 0;
    for (final range in merged) {
      if (range.$1 > index) {
        spans.add(TextSpan(
            text: text.substring(index, range.$1),
            style: style,
            recognizer: recognizer));
      }
      spans.add(TextSpan(
          text: text.substring(range.$1, range.$2),
          style: style.copyWith(backgroundColor: highlightBackground),
          recognizer: recognizer));
      index = range.$2;
    }
    if (index < text.length) {
      spans.add(TextSpan(
          text: text.substring(index), style: style, recognizer: recognizer));
    }
    return spans;
  }
}

enum _BlockType { heading, paragraph, quote, listItem, code, image, rule }

class _Block {
  final _BlockType type;
  final String text;
  final int level;
  final String? url;
  final String? marker;

  const _Block(this.type, this.text, {this.level = 0, this.url, this.marker});
}
