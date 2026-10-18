import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// A piece of text or an image that must not be cut across two pages, as
/// its top and bottom in the scrolled content.
typedef LineExtent = (double top, double bottom);

/// Where each page of a paged article starts (scroll offsets, the first
/// one 0), for content [contentHeight] tall shown [pageHeight] at a time.
///
/// [paragraphs] lists each paragraph's lines, top to bottom (an image is a
/// paragraph of one line). A page ends after its last whole line, never
/// through one, and preferably at the end of a paragraph: a paragraph is
/// split between pages only when moving it whole would leave more than a
/// third of the page empty. A page never ends with a paragraph's first line
/// alone, nor with a heading (one of [headings]): those move to the next
/// page with what follows them. Only something taller than a page is cut.
List<double> pageBreaks(List<List<LineExtent>> paragraphs, double pageHeight,
    double contentHeight,
    {Set<int> headings = const {}}) {
  final lines = <(double, double, int)>[
    for (var p = 0; p < paragraphs.length; p++)
      for (final (top, bottom) in paragraphs[p])
        if (bottom > top) (top, bottom, p),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  const eps = 0.5;

  /// Moves [y] up until no line is cut by it.
  double clear(double y) {
    var moved = true;
    while (moved) {
      moved = false;
      for (final (top, bottom, _) in lines) {
        if (top < y - eps && bottom > y + eps) {
          y = top;
          moved = true;
        }
      }
    }
    return y;
  }

  final starts = <double>[0];
  var start = 0.0;
  while (pageHeight > 0 && start + pageHeight < contentHeight - eps) {
    final limit = start + pageHeight;
    // The first line that doesn't fit whole on this page starts the next.
    final next = lines
        .where((l) => l.$1 >= start - eps && l.$2 > limit + eps)
        .firstOrNull;
    var y = limit;
    if (next != null) {
      // (Below the page's end when only an image's tail is left: cut there.)
      y = clear(next.$1 < limit ? next.$1 : limit);
      // Mid-paragraph: move the whole paragraph over when that keeps at
      // least two thirds of the page filled.
      final first = paragraphs[next.$3].first.$1;
      if (first < next.$1 - eps && first >= start + pageHeight * 2 / 3) {
        y = clear(first);
      }
    }
    y = _keepTogether(paragraphs, headings, start, y, clear);
    // Nothing fits whole (a line or an image taller than the page): cut.
    if (y <= start + eps) y = limit;
    starts.add(y);
    start = y;
  }
  return starts;
}

/// Moves the break [y] up so the page doesn't end with a paragraph's first
/// line alone, or with a heading cut off from its text. Leaves [y] alone
/// when that would empty the page.
double _keepTogether(List<List<LineExtent>> paragraphs, Set<int> headings,
    double start, double y, double Function(double) clear) {
  const eps = 0.5;
  var moved = y;
  // A paragraph split with only its first line on this page: move it all.
  for (final lines in paragraphs) {
    final first = lines.first.$1;
    if (first < moved - eps && lines.last.$2 > moved + eps) {
      if (lines.where((l) => l.$2 <= moved + eps).length < 2) {
        moved = clear(first);
      }
      break;
    }
  }
  // A heading (or a few stacked) right above the break goes with it.
  while (true) {
    int? before;
    for (var i = 0; i < paragraphs.length; i++) {
      final lines = paragraphs[i];
      if (lines.last.$2 <= moved + eps && lines.first.$1 >= start - eps) {
        if (before == null ||
            lines.last.$2 > paragraphs[before].last.$2) {
          before = i;
        }
      }
    }
    if (before == null || !headings.contains(before)) break;
    final top = clear(paragraphs[before].first.$1);
    if (top >= moved - eps) break;
    moved = top;
  }
  return moved > start + eps ? moved : y;
}

/// Whether a paragraph's text is all bold: a heading (or a bold line
/// standing in for one) that belongs with what follows.
bool _allBold(InlineSpan span, [FontWeight inherited = FontWeight.normal]) {
  final weight = span.style?.fontWeight ?? inherited;
  if (span is TextSpan) {
    final text = span.text ?? '';
    if (text.trim().isNotEmpty && weight.value < FontWeight.w600.value) {
      return false;
    }
    return (span.children ?? const <InlineSpan>[])
        .every((c) => _allBold(c, weight));
  }
  return true;
}

/// The lines of every paragraph and image laid out under [content], in the
/// coordinates of [scrollBox] scrolled by [scrollOffset].
///
/// Short paragraphs whose text is all bold are listed in `headings`.
({List<List<LineExtent>> paragraphs, Set<int> headings}) collectLines(
    RenderObject content, RenderBox scrollBox, double scrollOffset) {
  final paragraphs = <List<LineExtent>>[];
  final headings = <int>{};
  void visit(RenderObject node) {
    if (node is RenderParagraph) {
      final length = node.text.toPlainText().length;
      if (length == 0 || !node.hasSize) return;
      final dy =
          node.localToGlobal(Offset.zero, ancestor: scrollBox).dy + scrollOffset;
      final boxes = node.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: length),
          boxHeightStyle: ui.BoxHeightStyle.max);
      // Boxes come per run of text; overlapping ones share a line.
      final lines = <LineExtent>[];
      for (final box in boxes) {
        final (top, bottom) = (box.top + dy, box.bottom + dy);
        if (lines.isNotEmpty && top < lines.last.$2 - 1) {
          final (lt, lb) = lines.last;
          lines.last = (lt < top ? lt : top, lb > bottom ? lb : bottom);
        } else {
          lines.add((top, bottom));
        }
      }
      if (lines.isEmpty) return;
      if (lines.length <= 3 && _allBold(node.text)) {
        headings.add(paragraphs.length);
      }
      paragraphs.add(lines);
      return;
    }
    if (node is RenderImage && node.hasSize) {
      final top =
          node.localToGlobal(Offset.zero, ancestor: scrollBox).dy + scrollOffset;
      paragraphs.add([(top, top + node.size.height)]);
      return;
    }
    node.visitChildren(visit);
  }

  visit(content);
  return (paragraphs: paragraphs, headings: headings);
}
