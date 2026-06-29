// Acceptance test for a bookmarked tweet that quotes a native X Article.
// Run on a device with Twitter connected:
//
//   flutter test integration_test/twitter_quoted_article_test.dart -d <device>
import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _tweetId = '2070189404207853809'; // albertwenger, quotes the article

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quoted native article is inlined (contains "agentic traffic")',
      (tester) async {
    final twitter = TwitterService();
    if (!await twitter.isConnected) {
      markTestSkipped('Twitter is not connected on this device');
      return;
    }

    final item = await twitter.fetchTweet(_tweetId);
    debugPrint('linkedTweetId=${item.linkedTweetId} len=${item.text.length}');

    expect(item.text, contains('---'),
        reason: 'expected a rule between the tweet and the inlined article');
    expect(item.text, contains('agentic traffic'),
        reason: 'expected the inlined X Article body.\n\n${item.text}');
  });
}
