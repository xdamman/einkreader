// Unit tests for the pure tweet/article -> Markdown helpers. These mirror the
// X API v2 shapes so the conversion can be iterated on without a device (see
// also the `tweet_md` CLI).
import 'package:einkreader/services/twitter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expandTweetUrls', () {
    test('replaces t.co links with their expanded form', () {
      final body = {
        'text': 'see https://t.co/abc now',
        'entities': {
          'urls': [
            {'url': 'https://t.co/abc', 'expanded_url': 'https://example.com/x'}
          ]
        }
      };
      expect(expandTweetUrls(body), 'see https://example.com/x now');
    });
  });

  group('linkedTweetId', () {
    test('prefers a quoted reference', () {
      final tweet = {
        'referenced_tweets': [
          {'type': 'replied_to', 'id': '1'},
          {'type': 'quoted', 'id': '42'},
        ]
      };
      expect(linkedTweetId(tweet, tweet), '42');
    });

    test('falls back to an x.com status link in the text', () {
      final tweet = {
        'entities': {
          'urls': [
            {'expanded_url': 'https://x.com/u/status/99'}
          ]
        }
      };
      expect(linkedTweetId(tweet, tweet), '99');
    });

    test('ignores non-status x.com links and external links', () {
      final tweet = {
        'entities': {
          'urls': [
            {'expanded_url': 'https://x.com/i/article/123'},
            {'expanded_url': 'https://blog.example.com/post'},
          ]
        }
      };
      expect(linkedTweetId(tweet, tweet), isNull);
    });
  });

  group('articleToMarkdown', () {
    final article = {
      'title': 'The Rebel Alliance',
      'cover_media': '3_999',
      'plain_text':
          'First paragraph with a point.\nSecond paragraph continues.',
      'entities': {
        'tweets': [
          {'id': '555'}
        ],
      },
    };

    test('renders heading, cover image, and paragraphs split on newlines', () {
      final md = articleToMarkdown(article,
          mediaUrls: {'3_999': 'https://cdn/cover.jpg'});
      expect(md, startsWith('# The Rebel Alliance'));
      expect(md, contains('![](https://cdn/cover.jpg)'));
      // Single newlines in plain_text become blank-line paragraph breaks.
      expect(md, contains('First paragraph with a point.\n\n'
          'Second paragraph continues.'));
      expect(md, isNot(contains('point.\nSecond')));
    });

    test('omits the cover image when its media url is unknown', () {
      final md = articleToMarkdown(article);
      expect(md, isNot(contains('![]')));
    });

    test('restores bold "Term:" lead-ins and short heading lines', () {
      final formatted = articleToMarkdown({
        'title': 'T',
        'plain_text': "Where we're looking\n"
            'Browser: What does a browser for agents look like?\n'
            'Memory: control of context\n'
            'This is an ordinary body paragraph that is far too long to be '
            'mistaken for a section heading by the formatter.',
      });
      expect(formatted, contains("## Where we're looking"));
      expect(formatted, contains('**Browser:** What does a browser'));
      // A short "Term: x" with no end punctuation is bolded, not made a heading.
      expect(formatted, contains('**Memory:** control of context'));
      expect(formatted, isNot(contains('## Memory')));
      expect(formatted, contains('This is an ordinary body paragraph'));
      expect(formatted, isNot(contains('## This is an ordinary')));
    });

    test('appends embedded posts that were resolved', () {
      final md = articleToMarkdown(article, embeddedPosts: {
        '555': postBlockquote('Hello there', authorUsername: 'someone'),
      });
      expect(md, contains('---'));
      expect(md, contains('> Hello there'));
      expect(md, contains('— @someone'));
    });
  });

  group('tweetBodyMarkdown', () {
    test('uses the X Article body when present', () {
      final tweet = {
        'text': 'https://t.co/link',
        'article': {'title': 'T', 'plain_text': 'Body line one.'},
      };
      expect(isLongFormTweet(tweet), isTrue);
      expect(tweetBodyMarkdown(tweet), '# T\n\nBody line one.');
    });

    test('uses the note_tweet body when present', () {
      final tweet = {
        'text': 'truncated…',
        'note_tweet': {'text': 'the full longer body'},
      };
      expect(isLongFormTweet(tweet), isTrue);
      expect(tweetBodyMarkdown(tweet), 'the full longer body');
    });

    test('falls back to plain tweet text', () {
      final tweet = {'text': 'just a tweet'};
      expect(isLongFormTweet(tweet), isFalse);
      expect(tweetBodyMarkdown(tweet), 'just a tweet');
    });

    test('appends attached photos and drops the media-page link', () {
      final tweet = {
        'text': 'look at this https://t.co/x',
        'entities': {
          'urls': [
            {
              'url': 'https://t.co/x',
              'expanded_url': 'https://x.com/u/status/1/photo/1',
            }
          ]
        },
        'attachments': {
          'media_keys': ['m1']
        },
      };
      final md = tweetBodyMarkdown(tweet, mediaUrls: {'m1': 'https://cdn/p.jpg'});
      expect(md, startsWith('look at this'));
      expect(md, isNot(contains('/photo/')));
      expect(md, contains('![](https://cdn/p.jpg)'));
    });
  });

  group('postBlockquote', () {
    test('quotes every line and adds attribution', () {
      final md = postBlockquote('line one\nline two', authorName: 'Jane');
      expect(md, '> line one\n> line two\n>\n> — Jane');
    });
  });
}
