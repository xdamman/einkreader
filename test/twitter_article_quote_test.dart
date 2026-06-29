// Reproducible, network-free test for a tweet that quotes a native X Article
// (as opposed to a note_tweet). Mirrors the real X API v2 shapes captured for
// https://x.com/albertwenger/status/2070189404207853809, which quotes the
// article https://x.com/nickgrossman/status/2070181707613937866 ("The Rebel
// Alliance"). The article body lives in `article.plain_text`.
import 'dart:convert';

import 'package:einkreader/services/twitter_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _tweetId = '2070189404207853809';
const _articleId = '2070181707613937866';

const _wenger = {'id': '7015112', 'name': 'Albert Wenger', 'username': 'albertwenger'};
const _grossman = {'id': '14375609', 'name': 'Nick Grossman', 'username': 'nickgrossman'};

// Excerpt of the real article.plain_text — the phrase under test is in there.
const _articlePlainText =
    'We believe that the AI opportunity is too big to be owned by any one '
    'company. We refer to it as the Rebel Alliance.\n'
    'As of this writing, agentic traffic on the web has surpassed human '
    'traffic for the first time in history. Over the coming years, agents will '
    'be woven into all of our online experiences.';

Map<String, dynamic> _quotingJson() => {
      'data': {
        'id': _tweetId,
        'author_id': _wenger['id'],
        'created_at': '2026-06-25T16:56:30.000Z',
        'text': 'Come and join the rebel alliance! https://t.co/0kTHcNTddc',
        'entities': {
          'urls': [
            {
              'url': 'https://t.co/0kTHcNTddc',
              'expanded_url':
                  'https://twitter.com/nickgrossman/status/$_articleId',
            }
          ]
        },
        'referenced_tweets': [
          {'type': 'quoted', 'id': _articleId},
        ],
      },
      'includes': {
        'users': [_wenger],
        'tweets': [
          {'id': _articleId, 'article': {'title': 'The Rebel Alliance'}},
        ],
      },
    };

Map<String, dynamic> _articleJson() => {
      'data': {
        'id': _articleId,
        'author_id': _grossman['id'],
        'created_at': '2026-06-25T16:25:55.000Z',
        // An X Article's top-level text is just its own link; the body is in
        // the article object.
        'text': 'https://t.co/GBy2md7JxD',
        'article': {
          'title': 'The Rebel Alliance',
          'plain_text': _articlePlainText,
        },
      },
      'includes': {
        'users': [_grossman],
      },
    };

void main() {
  test('a tweet quoting a native X Article inlines the article body', () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/tweets/$_tweetId')) {
        return http.Response(jsonEncode(_quotingJson()), 200,
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

    // Tweet first, then a rule, then the article (headline + body).
    expect(item.text, startsWith('Come and join the rebel alliance!'));
    expect(item.text, contains('\n\n---\n\n'));
    expect(item.text, contains('# The Rebel Alliance'));
    expect(item.text, contains('agentic traffic'));
  });
}
