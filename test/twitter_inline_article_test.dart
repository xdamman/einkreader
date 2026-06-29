// Reproducible, network-free test of the article-inlining logic in
// TwitterService: a tweet that quotes a native long-form article should render
// as the tweet, a horizontal rule, then the full article body.
//
// The HTTP layer is faked, so this runs on the host VM with `flutter test` and
// needs no device or live Twitter connection. The shapes below mirror the X API
// v2 responses for https://x.com/RayDalio/status/2069127421291377016 (the tweet)
// and the article it quotes, https://x.com/RayDalio/status/2067702086460997687.
import 'dart:convert';

import 'package:einkreader/services/twitter_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _author = {'id': '44196397', 'name': 'Ray Dalio', 'username': 'RayDalio'};

// The real text of the quoting tweet (captured from the live API).
const _tweetText =
    'I recently spent a month in Asia, including 10 days in China, where I met '
    'with senior policy makers in several countries, and I found that over the '
    'past few months, there has been a big shift in the world order. I share my '
    'perspective in my latest article. \n\nAs always, I welcome your questions '
    'and thoughts.';

// The quoted article is a native long-form (note) tweet; its body mentions the
// British Empire.
const _articleText =
    'Why Nations Succeed and Fail: The Big Cycle.\n\n'
    'Throughout history the leading powers have risen and declined in a cycle. '
    'The Dutch, then the British Empire, and then the United States each rose to '
    'reserve-currency dominance and then declined as their advantages faded.';

const _tweetId = '2069127421291377016';
const _articleId = '2067702086460997687';

Map<String, dynamic> _tweetAJson() => {
      'data': {
        'id': _tweetId,
        'author_id': _author['id'],
        'created_at': '2026-06-12T12:00:00.000Z',
        'text': _tweetText,
        'referenced_tweets': [
          {'type': 'quoted', 'id': _articleId},
        ],
      },
      'includes': {
        'users': [_author],
        'tweets': [
          {'id': _articleId, 'author_id': _author['id']},
        ],
      },
    };

Map<String, dynamic> _articleJson() => {
      'data': {
        'id': _articleId,
        'author_id': _author['id'],
        'created_at': '2026-06-08T12:00:00.000Z',
        // Top-level text is truncated; the full body lives in note_tweet.
        'text': 'Why Nations Succeed and Fail: The Big Cycle…',
        'note_tweet': {'text': _articleText},
      },
      'includes': {
        'users': [_author],
      },
    };

void main() {
  test('a tweet quoting a native article inlines it below a horizontal rule',
      () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/tweets/$_tweetId')) {
        return http.Response(jsonEncode(_tweetAJson()), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/tweets/$_articleId')) {
        return http.Response(jsonEncode(_articleJson()), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });

    final twitter =
        TwitterService(client: client, accessToken: () async => 'test-token');

    final item = await twitter.fetchTweet(_tweetId);

    // Tweet first, then a markdown horizontal rule, then the article body.
    expect(item.text, startsWith(_tweetText));
    expect(item.text, contains('\n\n---\n\n'));
    expect(item.text, contains('British Empire'));
    expect(item.text.indexOf('---'),
        lessThan(item.text.indexOf('British Empire')),
        reason: 'the rule must come before the article body');
  });
}
