// Linked images — an <img> wrapped in an <a> — are emitted by html2md as
// `[ ![alt](src) ](href)`, often split across lines. Before the fix the block
// renderer showed the wrapping link's `](href)` as a literal text fragment.
import 'package:einkreader/services/extractor.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a linked image is reduced to just the image in extracted markdown', () {
    // Substack-style: every chart image is wrapped in a link to a larger copy.
    final lead =
        'A long lead paragraph with enough text to clear the threshold. ' * 3;
    final tail =
        'A long trailing paragraph with enough text to clear it too. ' * 3;
    final html = '''
<div>
  <p>$lead</p>
  <a href="https://cdn.example.com/full/chart.png">
    <img src="https://cdn.example.com/w_1456/chart.png" alt="A chart">
  </a>
  <p>$tail</p>
</div>''';

    final md = ArticleExtractor.extract(html, baseUrl: 'https://example.com')!;

    // The image survives…
    expect(md, contains('![A chart](https://cdn.example.com/w_1456/chart.png)'));
    // …and there is no orphaned link fragment on its own line.
    final orphan = md
        .split('\n')
        .where((l) => l.trimLeft().startsWith('](') || l.trim() == '[');
    expect(orphan, isEmpty, reason: 'no broken `](href)` / `[` fragments');
  });

  testWidgets('the renderer shows the image, not literal link/image markup',
      (tester) async {
    const markdown =
        'Intro paragraph.\n\n'
        '![A chart](https://cdn.example.com/w_1456/chart.png)\n\n'
        'See the [source](https://example.com/post) for details.';

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: MarkdownView(markdown: markdown)),
      ),
    ));

    // The image block renders as an actual Image widget.
    expect(find.byType(Image), findsOneWidget);

    // No raw markdown punctuation leaks into the rendered text.
    final texts = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((rt) => (rt.text as TextSpan).toPlainText())
        .join('\n');
    expect(texts, isNot(contains('](http')));
    expect(texts, isNot(contains('![')));
    // The link's visible label is still present.
    expect(texts, contains('source'));
  });
}
