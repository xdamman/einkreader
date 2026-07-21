// Self-threads: fetching a tweet whose author replied to themselves returns
// the whole thread — tweets separated by horizontal rules, each segment
// carrying its own images (downloaded later by the normal localize pass).
import 'dart:convert';

import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _rootJson() => {
      'data': {
        'id': '100',
        'author_id': 'u1',
        'text': 'Thread start 1/3 https://t.co/x/photo/1',
        'created_at': '2026-07-20T10:00:00.000Z',
        'attachments': {
          'media_keys': ['m1']
        },
      },
      'includes': {
        'users': [
          {'id': 'u1', 'name': 'Vitalik', 'username': 'vitalikbuterin'}
        ],
        'media': [
          {'media_key': 'm1', 'type': 'photo', 'url': 'https://cdn/one.jpg'}
        ],
      },
    };

Map<String, dynamic> _timelineJson({required bool withThread}) => {
      'data': [
        if (withThread) ...[
          {
            'id': '102',
            'author_id': 'u1',
            'text': 'Final point 3/3',
            'referenced_tweets': [
              {'type': 'replied_to', 'id': '101'}
            ],
          },
          {
            'id': '101',
            'author_id': 'u1',
            'text': 'Second point 2/3 https://t.co/x/photo/2',
            'referenced_tweets': [
              {'type': 'replied_to', 'id': '100'}
            ],
            'attachments': {
              'media_keys': ['m2']
            },
          },
        ],
        {
          'id': '103',
          'author_id': 'u1',
          'text': 'unrelated new tweet',
        },
      ],
      'includes': {
        'media': [
          {'media_key': 'm2', 'type': 'photo', 'url': 'https://cdn/two.jpg'}
        ],
      },
    };

TwitterService _service({required bool withThread}) => TwitterService(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/tweets/100')) {
          return http.Response(jsonEncode(_rootJson()), 200,
              headers: {'content-type': 'application/json'});
        }
        if (path.endsWith('/users/u1/tweets')) {
          expect(request.url.queryParameters['since_id'], '100');
          return http.Response(
              jsonEncode(_timelineJson(withThread: withThread)), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('unexpected ${request.url}', 404);
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('a self-thread is fetched whole, rules between tweets, images kept',
      () async {
    final item = await _service(withThread: true).fetchTweet('100');

    final parts = item.text.split('\n\n---\n\n');
    expect(parts, hasLength(3));
    expect(parts[0], contains('Thread start 1/3'));
    expect(parts[0], contains('![](https://cdn/one.jpg)'));
    expect(parts[1], contains('Second point 2/3'));
    expect(parts[1], contains('![](https://cdn/two.jpg)'));
    expect(parts[2], contains('Final point 3/3'));
    // The thread is the article: keep it, don't chase linked pages.
    expect(item.isLongForm, isTrue);
    // The unrelated same-author tweet is not part of the chain.
    expect(item.text, isNot(contains('unrelated')));
  });

  test('no self-reply means the tweet stays a single post', () async {
    final item = await _service(withThread: false).fetchTweet('100');
    expect(item.text, isNot(contains('---')));
    expect(item.text, contains('Thread start 1/3'));
    expect(item.isLongForm, isFalse);
  });
}
