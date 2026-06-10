import 'package:einkreader/services/extractor.dart';
import 'package:einkreader/services/feed_parser.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FeedParser', () {
    test('parses RSS 2.0 with content:encoded', () {
      const xml = '''
<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>My Blog</title>
    <item>
      <title>Hello</title>
      <link>https://example.com/hello</link>
      <guid>hello-1</guid>
      <pubDate>Tue, 10 Jun 2026 08:30:00 +0200</pubDate>
      <description>Short summary</description>
      <content:encoded><![CDATA[<p>Full content here</p>]]></content:encoded>
    </item>
  </channel>
</rss>''';
      final feed = FeedParser.parse(xml);
      expect(feed.title, 'My Blog');
      expect(feed.items, hasLength(1));
      final item = feed.items.first;
      expect(item.guid, 'hello-1');
      expect(item.link, 'https://example.com/hello');
      expect(item.contentHtml, contains('Full content here'));
      expect(item.published, DateTime.utc(2026, 6, 10, 6, 30));
    });

    test('parses Atom feeds', () {
      const xml = '''
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Blog</title>
  <entry>
    <id>urn:uuid:1</id>
    <title>Entry one</title>
    <link rel="alternate" href="https://example.com/1"/>
    <published>2026-06-01T10:00:00Z</published>
    <summary>sum</summary>
  </entry>
</feed>''';
      final feed = FeedParser.parse(xml);
      expect(feed.title, 'Atom Blog');
      expect(feed.items.single.link, 'https://example.com/1');
      expect(feed.items.single.published, DateTime.utc(2026, 6, 1, 10));
    });
  });

  group('NostrService', () {
    test('decodes a known npub to its hex pubkey', () {
      // Well-known test vector (jack's npub).
      const npub =
          'npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m';
      expect(
          NostrService.decodeNpub(npub),
          '82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2');
    });

    test('rejects garbage input', () {
      expect(() => NostrService.decodeNpub('npub1invalid!'),
          throwsFormatException);
      expect(() => NostrService.decodeNpub('nsec1xyz'),
          throwsFormatException);
    });

    test('firstUrl skips bare images and finds article links', () {
      expect(
          NostrService.firstUrl(
              'look https://a.com/pic.jpg and https://b.com/post'),
          'https://b.com/post');
      expect(NostrService.firstUrl('no links here'), isNull);
    });
  });

  group('ArticleExtractor', () {
    test('extracts the article body and converts it to markdown', () {
      final paragraph = 'Sentence with enough length to count. ' * 5;
      final html = '''
<html><head><title>Page Title</title></head><body>
  <nav><a href="/">Home</a></nav>
  <article>
    <h1>The Story</h1>
    <p>$paragraph</p>
    <p>$paragraph</p>
  </article>
  <footer>copyright</footer>
</body></html>''';
      final markdown = ArticleExtractor.extract(html);
      expect(markdown, isNotNull);
      expect(markdown, contains('# The Story'));
      expect(markdown, contains('Sentence with enough length'));
      expect(markdown, isNot(contains('copyright')));
      expect(ArticleExtractor.extractTitle(html), 'Page Title');
    });

    test('returns null when there is no real content', () {
      expect(ArticleExtractor.extract('<html><body><p>hi</p></body></html>'),
          isNull);
    });
  });
}
