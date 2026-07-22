import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/archive_store.dart';
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

  /// Called with the full highlight text and the tap position when the user
  /// taps a painted highlight, so the reader can anchor a small menu there
  /// (share / note / remove).
  final void Function(String highlightText, Offset position)? onHighlightTap;

  /// Called when a link is tapped, with its URL and anchor text. When null,
  /// links open in the external browser.
  final void Function(String url, String anchorText)? onLinkTap;

  const MarkdownView({
    super.key,
    required this.markdown,
    this.highlights = const [],
    this.fontSize = 18,
    this.onHighlightTap,
    this.onLinkTap,
  });

  @override
  State<MarkdownView> createState() => _MarkdownViewState();

  /// The rendered plain text of each visible block, in order — what
  /// SelectionArea puts in a selection.
  static List<String> plainBlockTexts(String markdown) => [
        for (final block in _MarkdownViewState._parseBlocks(markdown))
          if (!_MarkdownViewState._isBoilerplate(block))
            switch (block.type) {
              _BlockType.code => block.text,
              _BlockType.image => '',
              _BlockType.rule => '',
              _ => _MarkdownViewState._plainInline(block.text),
            }
      ]..removeWhere((t) => t.trim().isEmpty);

  /// Re-inserts the newlines Flutter's SelectionArea drops between blocks: a
  /// selection spanning paragraphs arrives glued ("…ends here.Second
  /// paragraph…"), which can never be matched or shared correctly. Decomposes
  /// [selection] as suffix-of-block + whole blocks + prefix-of-block against
  /// [markdown]'s rendered blocks and joins the parts with '\n'. Returns the
  /// selection unchanged when it fits inside one block or can't be decomposed.
  static String repairSelection(String selection, String markdown) {
    if (selection.isEmpty) return selection;
    final blocks = plainBlockTexts(markdown);
    for (final block in blocks) {
      if (block.contains(selection)) return selection;
    }
    for (var i = 0; i < blocks.length; i++) {
      // Longest prefix of the selection that ends block i.
      final maxOverlap = selection.length < blocks[i].length
          ? selection.length
          : blocks[i].length;
      for (var overlap = maxOverlap; overlap > 0; overlap--) {
        if (!blocks[i].endsWith(selection.substring(0, overlap))) continue;
        final parts = [selection.substring(0, overlap)];
        var rest = selection.substring(overlap);
        var matched = rest.isEmpty;
        for (var j = i + 1; rest.isNotEmpty && j < blocks.length; j++) {
          if (rest.startsWith(blocks[j])) {
            parts.add(blocks[j]);
            rest = rest.substring(blocks[j].length);
            matched = rest.isEmpty;
          } else if (blocks[j].startsWith(rest)) {
            parts.add(rest);
            rest = '';
            matched = true;
          } else {
            break;
          }
        }
        if (matched && parts.length > 1) return parts.join('\n');
      }
    }
    return selection;
  }
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
    final blocks =
        _parseBlocks(widget.markdown).where((b) => !_isBoilerplate(b));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final block in blocks) _buildBlock(block)],
    );
  }

  // --------------------------------------------------------- boilerplate

  /// Standalone call-to-action injected mid-article by newsletter platforms
  /// (Substack's "Subscribe now", share/comment buttons). Matched only when
  /// it is the block's entire text, so real prose is never dropped.
  static final _ctaText = RegExp(
      r'^(subscribe( now)?|upgrade to paid|pledge( your support)?|'
      r'share( this post)?|leave a comment|give a gift subscription|'
      r'get \d+% off( for \d+ year)?|none of the above)$',
      caseSensitive: false);

  /// A lone link whose target is a subscribe endpoint, e.g.
  /// `[Subscribe now](https://foo.substack.com/subscribe)`.
  static final _subscribeLink = RegExp(
      r'^\[[^\]]*\]\((?:https?://)?[^)\s]*/subscribe\b[^)\s]*\)$');

  /// Whether [block] is newsletter boilerplate to hide. Applies to short text
  /// blocks and lone subscribe links; content blocks (code, images, quotes)
  /// are never touched.
  static bool _isBoilerplate(_Block block) {
    if (block.type != _BlockType.paragraph &&
        block.type != _BlockType.heading &&
        block.type != _BlockType.listItem) {
      return false;
    }
    final text = block.text.trim();
    if (_subscribeLink.hasMatch(text)) return true;
    // Compare on the visible text, so "**Subscribe now**" matches too.
    final plain = Article.plainTitle(text).trim();
    return _ctaText.hasMatch(plain);
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
        // No caption below the image: alt text is usually a filename or other
        // noise. It still serves as the placeholder when the image can't load.
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _image(block),
        );
      case _BlockType.rule:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(),
        );
    }
  }

  /// Renders an image block, preferring the offline copy when one was stored.
  Widget _image(_Block block) {
    final url = block.url ?? '';
    Widget caption() => block.text.isEmpty
        ? const SizedBox.shrink()
        : Text('[image: ${block.text}]',
            style: _bodyStyle.copyWith(
                fontStyle: FontStyle.italic, fontSize: widget.fontSize - 3));

    final local = ArchiveStore.localFile(url);
    if (local != null) {
      return Image.file(local, errorBuilder: (_, __, ___) => caption());
    }
    // Images that were not downloaded (e.g. failed) still try the network.
    return Image.network(url, errorBuilder: (_, __, ___) => caption());
  }

  static final _imageOnly =
      RegExp(r'^!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)$');
  static final _listLine = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
  static final _headingLine = RegExp(r'^(#{1,6})\s+(.*)$');

  static List<_Block> _parseBlocks(String markdown) {
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

      // Thematic break: 3+ of the same marker, optionally space-separated —
      // html2md emits hr as "* * *", which must win over the list parser.
      if (RegExp(r'^([*\-_])(?:\s*\1){2,}$').hasMatch(trimmed)) {
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

      // Indented continuation of a wrapped list item.
      if (line.startsWith('  ') &&
          paragraph.isEmpty &&
          blocks.isNotEmpty &&
          blocks.last.type == _BlockType.listItem) {
        final last = blocks.removeLast();
        blocks.add(_Block(last.type, '${last.text} $trimmed',
            level: last.level, marker: last.marker));
        continue;
      }

      paragraph.add(trimmed);
    }
    flushParagraph();
    return blocks;
  }

  // ---------------------------------------------------------- inline spans

  // The link alternatives allow EMPTY anchor text: pages carry invisible
  // heading self-links (`<a href="#…"></a>Title` → `[](url)Title`), which
  // must vanish rather than render literally. The last alternative is a
  // backslash-escaped link \[text\](url): html2md escapes brackets that
  // arrived as literal text, but bracketed text followed by a parenthesized
  // URL is in practice always a real link — render it as one instead of
  // leaving mangled text.
  static final _inlinePattern = RegExp(
      r'\*\*(.+?)\*\*|__(.+?)__|\*([^*\s][^*]*?)\*|_([^_\s][^_]*?)_|'
      r'`([^`]+)`|\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|'
      r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|'
      r'\\\[([^\]]*?)\\\]\(([^)\s]+)(?:\s+"[^"]*")?\)');

  /// The plain text [_inlineSpans] renders for [text] — same branches, but
  /// producing a string. Keeps [MarkdownView.plainBlockTexts] in lockstep
  /// with what SelectionArea actually sees.
  static String _plainInline(String text) {
    final out = StringBuffer();
    var index = 0;
    for (final match in _inlinePattern.allMatches(text)) {
      if (match.start > index) {
        out.write(_unescape(text.substring(index, match.start)));
      }
      if (match.group(1) != null || match.group(2) != null) {
        out.write(_plainInline(match.group(1) ?? match.group(2)!));
      } else if (match.group(3) != null || match.group(4) != null) {
        out.write(_plainInline(match.group(3) ?? match.group(4)!));
      } else if (match.group(5) != null) {
        out.write(match.group(5));
      } else if (match.group(6) != null || match.group(10) != null) {
        out.write(_unescape((match.group(6) ?? match.group(10))!));
      } else if (match.group(8) != null) {
        final alt = match.group(8)!;
        if (alt.isNotEmpty) out.write('[image: $alt]');
      }
      index = match.end;
    }
    if (index < text.length) out.write(_unescape(text.substring(index)));
    return out.toString();
  }

  List<InlineSpan> _inlineSpans(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in _inlinePattern.allMatches(text)) {
      if (match.start > index) {
        spans.addAll(
            _highlighted(text.substring(index, match.start), style));
      }
      if (match.group(1) != null || match.group(2) != null) {
        // Recurse so inline markup nested in the emphasis — most importantly
        // a [link](url) — still renders, inheriting the bold style.
        spans.addAll(_inlineSpans(match.group(1) ?? match.group(2)!,
            style.copyWith(fontWeight: FontWeight.w700)));
      } else if (match.group(3) != null || match.group(4) != null) {
        // Likewise for italics: a link inside *…* must stay a link.
        spans.addAll(_inlineSpans(match.group(3) ?? match.group(4)!,
            style.copyWith(fontStyle: FontStyle.italic)));
      } else if (match.group(5) != null) {
        spans.addAll(_highlighted(
            match.group(5)!,
            style.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const [],
                backgroundColor: const Color(0xFFEEEEEE)),
            unescape: false));
      } else if (match.group(6) != null || match.group(10) != null) {
        final url = (match.group(7) ?? match.group(11))!;
        final anchor = _unescape((match.group(6) ?? match.group(10))!);
        // Empty anchor text = an invisible in-page anchor: show nothing.
        if (anchor.isNotEmpty) {
          final recognizer = TapGestureRecognizer()
            ..onTap = () {
              final onLinkTap = widget.onLinkTap;
              if (onLinkTap != null) {
                onLinkTap(url, anchor);
              } else {
                launchUrl(Uri.parse(url),
                    mode: LaunchMode.externalApplication);
              }
            };
          _recognizers.add(recognizer);
          spans.addAll(_highlighted(
              anchor, style.copyWith(decoration: TextDecoration.underline),
              recognizer: recognizer));
        }
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
  /// newlines, so match each line separately. Each needle remembers the full
  /// highlight text it came from, so a tap can act on the whole highlight.
  Iterable<(String needle, String full)> get _highlightNeedles sync* {
    for (final highlight in widget.highlights) {
      for (final line in highlight.split('\n')) {
        final needle = line.trim();
        if (needle.length > 2) yield (needle, highlight);
      }
    }
  }

  /// html2md backslash-escapes Markdown punctuation found in page text
  /// (\[, \], \*, …); strip the escapes so readers see the literal character.
  /// Applied at render time, after inline parsing, so the escapes still keep
  /// that punctuation from being read as markup.
  static String _unescape(String text) => text.replaceAllMapped(
      RegExp(r'\\([\\`*_{}\[\]()#+\-.!>~|])'), (m) => m.group(1)!);

  /// Splits [text] so every saved highlight occurrence gets a grey wash, and
  /// (unless the span is already a link) makes it tappable to manage it.
  /// [unescape] is off for code spans, where backslashes are literal.
  List<InlineSpan> _highlighted(String rawText, TextStyle style,
      {TapGestureRecognizer? recognizer, bool unescape = true}) {
    final text = unescape ? _unescape(rawText) : rawText;
    final ranges = <(int, int, String)>[];
    for (final (needle, full) in _highlightNeedles) {
      var from = 0;
      while (true) {
        final at = text.indexOf(needle, from);
        if (at == -1) break;
        ranges.add((at, at + needle.length, full));
        from = at + needle.length;
      }
    }
    if (ranges.isEmpty) {
      return [TextSpan(text: text, style: style, recognizer: recognizer)];
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    // Merge overlapping ranges, keeping the first range's highlight text.
    final merged = <(int, int, String)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2, last.$3));
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
      // A link keeps its own tap; otherwise tapping manages the highlight.
      var spanRecognizer = recognizer;
      if (recognizer == null && widget.onHighlightTap != null) {
        final full = range.$3;
        final tap = TapGestureRecognizer()
          ..onTapUp = (details) =>
              widget.onHighlightTap!(full, details.globalPosition);
        _recognizers.add(tap);
        spanRecognizer = tap;
      }
      spans.add(TextSpan(
          text: text.substring(range.$1, range.$2),
          style: style.copyWith(backgroundColor: highlightBackground),
          recognizer: spanRecognizer));
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
