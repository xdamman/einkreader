// Network-free test that TwitterService.fetchBookmarks() turns a bookmarks
// timeline into the right TweetItems: it picks up every new post, expands a
// long-form note body, inlines attached photos, and surfaces an external
// article link. The HTTP layer and the stored user id are both faked, so this
// runs on the host VM with `flutter test` and needs no device or live
// connection (mirrors test/twitter_inline_article_test.dart).
import 'dart:convert';

import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _userId = '99';
const _author = {'id': '7', 'name': 'Ada', 'username': 'ada'};

Map<String, dynamic> _timelineJson() => {
      'data': [
        // A plain short tweet: no long-form body, no external link.
        {
          'id': '1',
          'author_id': _author['id'],
          'created_at': '2026-06-01T10:00:00.000Z',
          'text': 'just a plain thought',
        },
        // A "longer tweet": the full body lives in note_tweet.
        {
          'id': '2',
          'author_id': _author['id'],
          'created_at': '2026-06-02T10:00:00.000Z',
          'text': 'truncated…',
          'note_tweet': {'text': 'the full long body here'},
        },
        // A tweet with an attached photo; the API leaves a /photo/ media link.
        {
          'id': '3',
          'author_id': _author['id'],
          'created_at': '2026-06-03T10:00:00.000Z',
          'text': 'pic time https://t.co/p',
          'entities': {
            'urls': [
              {
                'url': 'https://t.co/p',
                'expanded_url': 'https://x.com/ada/status/3/photo/1',
              }
            ]
          },
          'attachments': {
            'media_keys': ['m1']
          },
        },
        // A tweet linking to an external article to download.
        {
          'id': '4',
          'author_id': _author['id'],
          'created_at': '2026-06-04T10:00:00.000Z',
          'text': 'great read https://t.co/a',
          'entities': {
            'urls': [
              {
                'url': 'https://t.co/a',
                'expanded_url': 'https://blog.example.com/post',
              }
            ]
          },
        },
      ],
      'includes': {
        'users': [_author],
        'media': [
          {'media_key': 'm1', 'type': 'photo', 'url': 'https://cdn/p.jpg'},
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The timeline endpoint reads the connected user id from secure storage.
    FlutterSecureStorage.setMockInitialValues({'twitter_user_id': _userId});
  });

  test('fetchBookmarks parses every new post in the timeline', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/users/$_userId/bookmarks')) {
        return http.Response(jsonEncode(_timelineJson()), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final twitter =
        TwitterService(client: client, accessToken: () async => 'test-token');

    final items = await twitter.fetchBookmarks();

    expect(items, hasLength(4));

    final plain = items[0];
    expect(plain.id, '1');
    expect(plain.isLongForm, isFalse);
    expect(plain.articleUrl, isNull);
    expect(plain.text, 'just a plain thought');

    final longForm = items[1];
    expect(longForm.isLongForm, isTrue);
    expect(longForm.text, 'the full long body here');

    final withPhoto = items[2];
    expect(withPhoto.text, startsWith('pic time'));
    expect(withPhoto.text, contains('![](https://cdn/p.jpg)'));
    expect(withPhoto.text, isNot(contains('/photo/')));

    final withArticle = items[3];
    expect(withArticle.isLongForm, isFalse);
    expect(withArticle.articleUrl, 'https://blog.example.com/post');
  });
}
