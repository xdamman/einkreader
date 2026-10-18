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
/// third of the page empty. Only something taller than a page is cut.
List<double> pageBreaks(List<List<LineExtent>> paragraphs, double pageHeight,
    double contentHeight) {
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
    // Nothing fits whole (a line or an image taller than the page): cut.
    if (y <= start + eps) y = limit;
    starts.add(y);
    start = y;
  }
  return starts;
}

/// The lines of every paragraph and image laid out under [content], in the
/// coordinates of [scrollBox] scrolled by [scrollOffset].
List<List<LineExtent>> collectLines(
    RenderObject content, RenderBox scrollBox, double scrollOffset) {
  final paragraphs = <List<LineExtent>>[];
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
      if (lines.isNotEmpty) paragraphs.add(lines);
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
  return paragraphs;
}
