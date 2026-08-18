// Multi-paragraph blockquotes (Daring Fireball-style link posts) must keep
// their paragraph breaks — and lists inside quotes their lines — instead of
// being glued into one wall of italic text.
import 'package:einkreader/services/extractor.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rendered plain text of the first quote block in a MarkdownView.
String _quoteText(WidgetTester tester) {
  final texts = <String>[];
  for (final rich in tester.widgetList<Text>(find.byType(Text))) {
    final span = rich.textSpan;
    if (span != null) texts.add(span.toPlainText());
  }
  return texts.firstWhere((t) => t.contains('exact'));
}

void main() {
  testWidgets('a quote with two paragraphs keeps the break', (tester) async {
    // What html2md produces for <blockquote><p>…</p><p>…</p></blockquote>.
    final markdown = ArticleExtractor.convertHtmlToMarkdown(
        '<p>Gruber writes:</p>'
        '<blockquote>'
        '<p>Code — which in very many cases has to be exact — has '
        'generally less watermarking.</p>'
        '<p>Having said that, the watermark can be used in comments.</p>'
        '</blockquote>');

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkdownView(markdown: markdown))));

    final quote = _quoteText(tester);
    expect(quote, contains('less watermarking.\n\nHaving said that'),
        reason: 'the two quoted paragraphs stay separate');
  });

  testWidgets('a list inside a quote keeps its lines and bullets',
      (tester) async {
    final markdown = ArticleExtractor.convertHtmlToMarkdown('<blockquote>'
        '<p>It has to be exact for three reasons:</p>'
        '<ul><li>first reason</li><li>second reason</li></ul>'
        '</blockquote>');

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkdownView(markdown: markdown))));

    final quote = _quoteText(tester);
    expect(quote, contains('• first reason\n'));
    expect(quote, contains('• second reason'));
    expect(quote, isNot(contains('first reason • second')),
        reason: 'list items never glue onto one line');
  });

  testWidgets('a single-paragraph quote still soft-wraps into one paragraph',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: MarkdownView(
                markdown: '> a line that was\n> wrapped by exactly the\n'
                    '> feed formatter'))));

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan?.toPlainText() ?? '')
        .toList();
    expect(
        texts,
        contains('a line that was wrapped by exactly the feed formatter'),
        reason: 'soft wraps still join with spaces');
  });
}
