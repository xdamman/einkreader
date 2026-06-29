// Live counterpart to test/twitter_inline_article_test.dart. Runs on a
// device/emulator that already has Twitter connected in the app and verifies
// the inlining against the real API:
//
//   flutter test integration_test/twitter_article_test.dart -d <device>
//
// It uses the OAuth tokens stored by the app, so it needs network access and a
// working connection (it is skipped otherwise). Note: the test reinstall cycle
// can clear the stored tokens, so you may need to reconnect between runs.
import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a tweet linking to a native article inlines the article body below a rule',
    (tester) async {
      final twitter = TwitterService();
      if (!await twitter.isConnected) {
        markTestSkipped('Twitter is not connected on this device');
        return;
      }

      // https://x.com/RayDalio/status/2069127421291377016 is a short tweet that
      // quotes the native article https://x.com/RayDalio/status/2067702086460997687.
      final item = await twitter.fetchTweet('2069127421291377016');

      // The tweet renders first, then a horizontal rule, then the full article.
      expect(item.text, contains('---'),
          reason: 'expected a horizontal rule between tweet and article');
      expect(item.text, contains('British Empire'),
          reason: 'expected the inlined article body.\n\n${item.text}');
    },
  );
}
