// Verifies that a Markdown link `[anchor](url)` is rendered as its anchor text
// only — underlined and tappable — with the bare URL never shown to the reader.
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flattens every TextSpan in a rendered RichText into (text, style) pairs.
List<(String, TextStyle?)> _spans(WidgetTester tester) {
  final out = <(String, TextStyle?)>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) out.add((span.text!, span.style));
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text);
  }
  return out;
}

void main() {
  testWidgets('renders [anchor](url) as underlined anchor text, no url',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'Visit [anchor](https://example.com/page) today.',
        ),
      ),
    ));

    final spans = _spans(tester);
    final text = spans.map((s) => s.$1).join();

    // The anchor text is shown, the URL is not.
    expect(text, contains('anchor'));
    expect(text, contains('Visit'));
    expect(text, contains('today.'));
    expect(text, isNot(contains('example.com')));
    expect(find.textContaining('example.com'), findsNothing);

    // The anchor span is styled as a link (underlined).
    final anchor = spans.firstWhere((s) => s.$1.contains('anchor'));
    expect(anchor.$2?.decoration, TextDecoration.underline);
  });

  testWidgets('a link inside italics stays a link (and is italic)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'See *the [full report](https://example.com/report) '
              'here* for details.',
        ),
      ),
    ));

    final spans = _spans(tester);
    final text = spans.map((s) => s.$1).join();
    expect(text, contains('full report'));
    expect(text, isNot(contains('example.com')));
    expect(text, isNot(contains('[')), reason: 'no raw markdown left');

    final anchor = spans.firstWhere((s) => s.$1.contains('full report'));
    // Rendered as a link…
    expect(anchor.$2?.decoration, TextDecoration.underline);
    // …and still italic from the surrounding emphasis.
    expect(anchor.$2?.fontStyle, FontStyle.italic);
    // Surrounding emphasised text is italic but not underlined.
    final around = spans.firstWhere((s) => s.$1.contains('here'));
    expect(around.$2?.fontStyle, FontStyle.italic);
    expect(around.$2?.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('a link inside bold stays a tappable link', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'Read **the [announcement](https://example.com/post)** '
              'today.',
        ),
      ),
    ));
    final spans = _spans(tester);
    final anchor = spans.firstWhere((s) => s.$1.contains('announcement'));
    expect(anchor.$2?.decoration, TextDecoration.underline);
    expect(anchor.$2?.fontWeight, FontWeight.w700);
  });

  testWidgets('newsletter "Subscribe now" boilerplate is hidden',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'Real opening paragraph of the article.\n\n'
              'Subscribe now\n\n'
              '[Subscribe now](https://foo.substack.com/subscribe)\n\n'
              '**Share this post**\n\n'
              'Real closing paragraph continues here.',
        ),
      ),
    ));
    final text = _spans(tester).map((s) => s.$1).join('\n');
    expect(text, contains('Real opening paragraph'));
    expect(text, contains('Real closing paragraph'));
    expect(text, isNot(contains('Subscribe now')));
    expect(text, isNot(contains('Share this post')));
    expect(text, isNot(contains('substack.com')));
  });

  testWidgets('a real sentence mentioning subscribe is kept', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'You can subscribe now to receive weekly updates by '
              'email, which many readers find convenient.',
        ),
      ),
    ));
    final text = _spans(tester).map((s) => s.$1).join();
    expect(text, contains('subscribe now to receive weekly updates'));
  });
}
