// Verifies that the feed view (ArticleFeed) renders article titles free of
// Markdown syntax and bare URLs, exercising Article.displayTitle end-to-end
// through the widget that shows it.
import 'package:einkreader/models.dart';
import 'package:einkreader/widgets/article_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Article _article(String title) => Article(
      id: 1,
      sourceId: 1,
      guid: 'g1',
      title: title,
      createdAt: DateTime(2026, 6, 6).millisecondsSinceEpoch,
    );

void main() {
  testWidgets('feed titles are free of markdown and urls', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArticleFeed(
          articles: [
            _article('## **Big** news: read [the post](https://blog.dev/x) '
                'at https://t.co/abc'),
          ],
          emptyMessage: 'none',
          onChanged: () {},
        ),
      ),
    ));

    // Anchor text is kept; heading/emphasis markers and both URLs are gone.
    expect(find.text('Big news: read the post at'), findsOneWidget);
    expect(find.textContaining('http'), findsNothing);
    expect(find.textContaining('*'), findsNothing);
    expect(find.textContaining(']('), findsNothing);
  });
}
