import 'package:einkreader/widgets/page_breaks.dart';
import 'package:flutter_test/flutter_test.dart';

/// [count] lines of height 10 from [top], 2px apart.
List<LineExtent> lines(double top, int count) =>
    [for (var i = 0; i < count; i++) (top + i * 12, top + i * 12 + 10)];

void main() {
  test('a page ends at the end of a paragraph that fits whole', () {
    // Paragraphs at 0–94 (8 lines) and 100–194: a 150px page would end
    // mid second paragraph; it ends after the first instead.
    final starts = pageBreaks([lines(0, 8), lines(100, 8)], 150, 194);
    expect(starts, [0, 100]);
  });

  test('a long paragraph splits between lines, never through one', () {
    final starts = pageBreaks([lines(0, 30)], 100, 358);
    expect(starts.first, 0);
    for (final start in starts.skip(1)) {
      expect(start % 12, 0, reason: 'starts on a line: $start');
    }
    for (var i = 1; i < starts.length; i++) {
      expect(starts[i] - starts[i - 1], lessThanOrEqualTo(100));
      // Fills the page: at most one line's worth left blank.
      expect(starts[i] - starts[i - 1], greaterThan(100 - 12));
    }
  });

  test('a paragraph moves over only if the page stays two-thirds full', () {
    // The second paragraph starts at 40: moving it whole would leave the
    // page 60% empty, so it splits after its last whole line.
    final starts = pageBreaks([lines(0, 3), lines(40, 20)], 100, 280);
    expect(starts[1], 100);
  });

  test('an image taller than the page is cut; the text after it is not', () {
    final starts = pageBreaks([
      [(0, 250)],
      lines(260, 5),
    ], 100, 318);
    // The image's tail shares page 3 with the first whole lines of text.
    expect(starts, [0, 100, 200, 296]);
  });

  test('a heading never ends a page: it moves over with its text', () {
    // Text to 94, a heading at 100–110, its paragraph from 120. The page
    // (0–150) could hold the heading and two lines, but the paragraph
    // would split; it moves whole, and the heading goes with it.
    final starts = pageBreaks(
        [lines(0, 8), lines(100, 1), lines(120, 10)], 150, 238,
        headings: {1});
    expect(starts[1], 100);
  });

  test('a heading with room for only one line of its text moves over', () {
    // Long paragraph to 154, heading 160–170, text from 180: a 200px page
    // holds the heading and one line, so both go to the next page.
    final starts = pageBreaks(
        [lines(0, 13), lines(160, 1), lines(180, 20)], 200, 418,
        headings: {1});
    expect(starts[1], 160);
  });

  test("a paragraph's first line is never left alone at a page's end", () {
    // 130px page: the second paragraph (from 120) would show one line.
    final starts = pageBreaks([lines(0, 10), lines(120, 10)], 130, 238);
    expect(starts[1], 120);
  });

  test('a page that fits is one page', () {
    expect(pageBreaks([lines(0, 5)], 100, 58), [0]);
  });
}
