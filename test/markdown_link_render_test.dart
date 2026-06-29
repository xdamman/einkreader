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
}
