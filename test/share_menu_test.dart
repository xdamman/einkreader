// The reader's share menu (top-right): open in browser, share the article or
// its highlights by email, and — when Twitter is connected — post a tweet.
// Also covers TwitterService.postTweet against a fake API.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/share_actions.dart';
import 'package:einkreader/services/tweet_card.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/highlight_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:einkreader/services/reading_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late int articleId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_share_menu');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));

    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'shared',
      title: 'A Shareable Story',
      url: 'https://example.com/shareable',
      contentMarkdown: 'A fine passage worth quoting.',
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
    ));
    articleId = (await db.getArticles()).single.id!;
    await db.insertHighlight(Highlight(
        articleId: articleId,
        text: 'A fine passage worth quoting.',
        createdAt: 1));
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('the article menu holds text size, share, reprocess and '
      'feedback; text size steps without closing it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: articleId),
    ));
    await settle(tester);
    final appBar = find.byType(AppBar);
    expect(find.descendant(of: appBar, matching: find.byType(IconButton)),
        findsOneWidget,
        reason: 'only the menu (no back button on a first route)');

    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    for (final item in ['Text size', 'Share', 'Reload', 'Send feedback']) {
      expect(find.text(item), findsOneWidget);
    }
    final before = ReadingSettings.instance.prefs.value.fontSize;
    await tester.tap(find.byTooltip('Larger text'));
    await tester.pump();
    await tester.tap(find.byTooltip('Larger text'));
    await settle(tester);
    expect(ReadingSettings.instance.prefs.value.fontSize, before + 4);
    expect(find.text('Send feedback'), findsOneWidget,
        reason: 'still open for another step');
    await tester.tap(find.byTooltip('Smaller text'));
    await settle(tester);
    expect(ReadingSettings.instance.prefs.value.fontSize, before + 2);
  });

  testWidgets('share menu lists browser + email options (no Twitter here)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: articleId),
    ));
    await settle(tester);

    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await tester.tap(find.text('Share'));
    await settle(tester);

    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text('Copy url'), findsOneWidget);
    expect(find.text('Share article by email'), findsOneWidget);
    expect(find.text('Share highlights by email'), findsOneWidget);
    // The menu subtitle plus the bottom-of-article "Share your 1
    // highlight" button behind the sheet.
    expect(find.textContaining('1 highlight'), findsNWidgets(2));
    // No Twitter account connected in the test environment.
    expect(find.text('Share on Twitter'), findsNothing);
    expect(find.text('Share highlights on Twitter'), findsNothing);
  });

  testWidgets('highlights tab: each row has a share button with a menu',
      (tester) async {
    final highlights =
        await tester.runAsync(() => db.getHighlights()) ?? [];
    expect(highlights, isNotEmpty);
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: HighlightList(highlights: highlights, onChanged: () {}),
      ),
    ));
    await settle(tester);

    await tester.tap(find.byTooltip('Share highlight').first);
    await settle(tester);
    await settle(tester); // the dialog's own async load
    await settle(tester);
    // The merged note/share overlay opens with the quote and note field.
    expect(find.text('Your note (optional)'), findsOneWidget);
    expect(find.text('Compose an email…'), findsOneWidget);
    expect(find.text('Tweet it'), findsOneWidget); // visible but locked
  });

  testWidgets(
      'tapping a highlight opens an anchored menu: note, share, remove',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: articleId),
    ));
    await settle(tester);

    // Fire the highlight span's tap (recognizers live on the painted span).
    TapGestureRecognizer? highlightTap;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.style?.backgroundColor != null &&
            span.recognizer is TapGestureRecognizer) {
          highlightTap = span.recognizer as TapGestureRecognizer;
        }
        (span.children ?? const <InlineSpan>[]).forEach(walk);
      }
    }

    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(rich.text);
    }
    expect(highlightTap, isNotNull, reason: 'highlight is painted+tappable');
    highlightTap!.onTapUp!(TapUpDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(300, 300)));
    await settle(tester);

    // The anchored menu (no bottom sheet): note, composer, remove.
    expect(find.text('Add note'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    expect(find.text('Remove highlight'), findsOneWidget);

    // Attach a note, reopen: the entry now reads "Edit note".
    await tester.tap(find.text('Add note'));
    await settle(tester);
    await settle(tester); // the dialog's own async load
    await tester.enterText(find.byType(TextField), 'a thought');
    await tester.tap(find.text('Save'));
    await settle(tester);
    final noted = (await tester.runAsync(() => db.getHighlights()))!
        .firstWhere((h) => h.articleId == articleId);
    expect(noted.comment, 'a thought');

    highlightTap!.onTapUp!(TapUpDetails(
        kind: PointerDeviceKind.touch,
        globalPosition: const Offset(300, 300)));
    await settle(tester);
    expect(find.text('Edit note'), findsOneWidget);

    // Remove it — and restore afterwards for the later tests in this file.
    await tester.tap(find.text('Remove highlight'));
    await settle(tester);
    expect(
        (await tester.runAsync(() => db.getHighlights(articleId: articleId)))!,
        isEmpty);
    await tester.runAsync(() => db.insertHighlight(Highlight(
        articleId: articleId,
        text: 'A fine passage worth quoting.',
        createdAt: 1)));
  });

  group('ShareActions.highlightsBody', () {
    const article = Article(
        sourceId: 1,
        guid: 'g',
        title: 'The Story',
        url: 'https://example.com/story',
        createdAt: 0);

    test('single highlight: quote with one attribution', () {
      final body = ShareActions.highlightsBody(article,
          [const Highlight(articleId: 1, text: 'a passage', createdAt: 0)]);
      expect(body, '"a passage"\n\n— The Story (https://example.com/story)');
    });

    test('several highlights: one attribution up front, all quotes', () {
      final body = ShareActions.highlightsBody(article, [
        const Highlight(articleId: 1, text: 'first', createdAt: 0),
        const Highlight(articleId: 1, text: 'second', createdAt: 0),
      ]);
      expect(
          body,
          'My highlights from The Story (https://example.com/story):\n\n'
          '"first"\n\n"second"');
      // The attribution appears exactly once.
      expect('example.com/story'.allMatches(body), hasLength(1));
    });

    test('withAttribution: false gives quotes only (for quote tweets)', () {
      final body = ShareActions.highlightsBody(
        article,
        [const Highlight(articleId: 1, text: 'a passage', createdAt: 0)],
        withAttribution: false,
      );
      expect(body, '"a passage"');
    });
  });

  testWidgets('quote-tweet dialog shows a preview card of the original',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: OutlinedButton(
              onPressed: () => ShareActions.onTwitter(
                context,
                draft: '',
                quoted: const QuotedTweet(
                  id: '123',
                  authorName: '@someone',
                  username: 'someone',
                  text: 'The original tweet text',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('@someone'), findsOneWidget);
    expect(find.text('The original tweet text'), findsOneWidget);
    expect(find.text('Add your comment…'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  test('highlights are shared in reading order, not save order', () {
    const article = Article(
        sourceId: 1,
        guid: 'g',
        title: 'Ordered',
        contentMarkdown: 'Alpha passage first. Beta passage second. '
            'Gamma passage third.',
        createdAt: 0);
    // Saved newest-first (as getHighlights returns them).
    final highlights = [
      const Highlight(articleId: 1, text: 'Gamma passage', createdAt: 3),
      const Highlight(articleId: 1, text: 'Alpha passage', createdAt: 1),
      const Highlight(articleId: 1, text: 'Beta passage', createdAt: 2),
    ];
    final body = ShareActions.highlightsBody(article, highlights);
    expect(
        body.indexOf('Alpha'), lessThan(body.indexOf('Beta')));
    expect(body.indexOf('Beta'), lessThan(body.indexOf('Gamma')));
  });

  group('outbox', () {
    test('failed post is queued, retried, and sent when the API recovers',
        () async {
      var failing = true;
      OutboxService.instance.debugTwitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async => failing
            ? http.Response('{"detail": "over capacity"}', 503)
            : http.Response('{"data": {"id": "9"}}', 201)),
      );

      await OutboxService.instance
          .enqueueTweet('stuck tweet', error: 'offline');
      expect(OutboxService.instance.pending.value, 1);

      // Retry while the API still fails: stays queued, attempt recorded.
      var (sent, remaining) = await OutboxService.instance.flush();
      expect((sent, remaining), (0, 1));
      final item = (await OutboxService.instance.items()).single;
      expect(item.attempts, 2);
      expect(item.lastError, contains('503'));

      // API recovers: flush drains the queue.
      failing = false;
      (sent, remaining) = await OutboxService.instance.flush();
      expect((sent, remaining), (1, 0));
      expect(OutboxService.instance.pending.value, 0);
      OutboxService.instance.debugTwitter = null;
    });
  });

  test('a post refused for good is held, not retried', () async {
    var posts = 0;
    OutboxService.instance.debugTwitter = TwitterService(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        posts++;
        return http.Response('{"detail": "duplicate content"}', 403);
      }),
    );
    await OutboxService.instance.enqueueTweet('again', error: 'offline');
    await OutboxService.instance.flush();
    final item = (await OutboxService.instance.items()).single;
    expect(item.held, isTrue);
    expect(posts, 1);
    // Later flushes leave it alone; it waits to be discarded.
    final (sent, remaining) = await OutboxService.instance.flush();
    expect((sent, remaining), (0, 0));
    expect(posts, 1);
    expect(OutboxService.instance.pending.value, 1);
    await OutboxService.instance.delete(item.id!);
    OutboxService.instance.debugTwitter = null;
  });

  testWidgets('posting an empty tweet says so instead of dropping silently',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: OutlinedButton(
              onPressed: () => ShareActions.onTwitter(context,
                  draft: '',
                  quoted: const QuotedTweet(id: '123', text: 'x')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();
    expect(find.textContaining('the tweet was empty'), findsOneWidget);
  });

  group('TwitterService.tweetIdFromUrl', () {
    test('extracts the status id from tweet URLs', () {
      expect(
          TwitterService.tweetIdFromUrl(
              'https://x.com/xdamman/status/1234567890'),
          '1234567890');
      expect(
          TwitterService.tweetIdFromUrl(
              'https://twitter.com/xdamman/statuses/42?s=20'),
          '42');
      expect(
          TwitterService.tweetIdFromUrl(
              'https://mobile.twitter.com/xdamman/status/7'),
          '7');
    });

    test('anything else is null', () {
      expect(TwitterService.tweetIdFromUrl('https://example.com/status/1'),
          isNull);
      expect(TwitterService.tweetIdFromUrl('https://x.com/xdamman'), isNull);
      expect(
          TwitterService.tweetIdFromUrl('https://x.com/i/status/notanid'),
          isNull);
      expect(TwitterService.tweetIdFromUrl(null), isNull);
    });
  });

  group('TwitterService.tweetMaxLength', () {
    TwitterService withPlan(String? verifiedType) => TwitterService(
          accessToken: () async => 'token',
          client: MockClient((request) async {
            expect(request.url.path, '/2/users/me');
            return http.Response(
                jsonEncode({
                  'data': {
                    'id': '1',
                    if (verifiedType != null) 'verified_type': verifiedType,
                  }
                }),
                200);
          }),
        );

    test('Premium (blue) gets long posts', () async {
      expect(await withPlan('blue').tweetMaxLength(), 25000);
    });

    test('unverified gets 280', () async {
      expect(await withPlan('none').tweetMaxLength(), 280);
      expect(await withPlan(null).tweetMaxLength(), 280);
    });

    test('lookup failure falls back to 280', () async {
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async => http.Response('oops', 500)),
      );
      expect(await twitter.tweetMaxLength(), 280);
    });
  });

  group('TwitterService.postTweet', () {
    test('posts the text to /2/tweets', () async {
      String? posted;
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          expect(request.url.path, '/2/tweets');
          expect(request.headers['Authorization'], 'Bearer token');
          posted = (jsonDecode(request.body) as Map)['text'] as String;
          return http.Response('{"data": {"id": "1"}}', 201);
        }),
      );
      await twitter.postTweet('Read this: https://example.com');
      expect(posted, 'Read this: https://example.com');
    });

    test('quoteTweetId becomes a native quote tweet', () async {
      Map<String, dynamic>? body;
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"data": {"id": "1"}}', 201);
        }),
      );
      await twitter.postTweet('Great thread', quoteTweetId: '1234567890');
      expect(body, {'text': 'Great thread', 'quote_tweet_id': '1234567890'});
    });

    test('a refused quote is resent with a screenshot of the stored post',
        () async {
      final calls = <String>[];
      Map<String, dynamic>? tweet;
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/2/media/upload') {
            expect(request.headers['content-type'],
                startsWith('multipart/form-data'));
            return http.Response('{"data": {"id": "777"}}', 200);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body.containsKey('quote_tweet_id')) {
            return http.Response(
                '{"detail":"You can only reply to or quote posts where you '
                'are mentioned or are the author.","status":403}',
                403);
          }
          tweet = body;
          return http.Response('{"data": {"id": "1"}}', 201);
        }),
      );
      await twitter.postTweet('So true',
          quoted: const QuotedTweet(
              id: '42',
              authorName: 'Patrick Collison',
              username: 'patrickc',
              text: 'Brothers Karamazov was Einstein\'s favorite novel'));
      // Quote first; no lookup needed: the stored post is drawn.
      expect(calls,
          ['POST /2/tweets', 'POST /2/media/upload', 'POST /2/tweets']);
      // The screenshot comes with a link to the original post.
      expect(tweet, {
        'text': 'So true\n\nhttps://x.com/patrickc/status/42',
        'media': {
          'media_ids': ['777']
        },
      });
    });

    test('a refused quote is retried as a screenshot of the looked-up post',
        () async {
      final calls = <String>[];
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'GET') {
            return http.Response(
                jsonEncode({
                  'data': {
                    'id': '42',
                    'text': 'An interesting post',
                    'author_id': 'u1',
                    'created_at': '2026-10-10T15:34:19.000Z',
                  },
                  'includes': {
                    'users': [
                      {'id': 'u1', 'name': 'Someone', 'username': 'someone'}
                    ]
                  },
                }),
                200);
          }
          if (request.url.path == '/2/media/upload') {
            return http.Response('{"data": {"id": "9"}}', 200);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body.containsKey('quote_tweet_id')) {
            return http.Response(
                '{"detail":"You can only reply to or quote posts where you '
                'are mentioned or are the author.","status":403}',
                403);
          }
          expect(body['media'], {
            'media_ids': ['9']
          });
          expect(body['text'], 'Look\n\nhttps://x.com/someone/status/42');
          return http.Response('{"data": {"id": "1"}}', 201);
        }),
      );
      await twitter.postTweet('Look', quoteTweetId: '42');
      expect(calls, [
        'POST /2/tweets',
        'GET /2/tweets/42',
        'POST /2/media/upload',
        'POST /2/tweets',
      ]);
    });

    test('the link to the original post only goes in when it fits', () {
      const url = 'https://x.com/a/status/1';
      expect(TwitterService.withLinkTo('Hi', url), 'Hi\n\n$url');
      expect(TwitterService.withLinkTo('', url), url);
      // Already there: not twice.
      expect(TwitterService.withLinkTo('See $url', url), 'See $url');
      // 255 + 2 + 23 = 280 fits; one more character doesn't.
      expect(TwitterService.withLinkTo('a' * 255, url), endsWith(url));
      expect(TwitterService.withLinkTo('a' * 256, url), 'a' * 256);
      // Other links count 23, as X counts them.
      final withLink = 'https://example.com/${'p' * 100} ${'a' * 231}';
      expect(TwitterService.withLinkTo(withLink, url), endsWith(url));
      // Long-post accounts have room.
      expect(TwitterService.withLinkTo('a' * 500, url, maxLength: 25000),
          endsWith(url));
    });

    test('a duplicate is refused for good', () async {
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient((request) async => http.Response(
            '{"detail": "You are not allowed to create a Tweet with '
            'duplicate content."}',
            403)),
      );
      expect(
        twitter.postTweet('hello'),
        throwsA(isA<TwitterPostRefused>()
            .having((e) => e.permanent, 'permanent', isTrue)),
      );
    });

    test('the screenshot is a PNG of the post', () async {
      final png = await renderTweetCard(QuotedTweet(
          id: '42',
          authorName: 'Patrick Collison',
          username: 'patrickc',
          text: 'Line one\n\nLine two',
          createdAt: DateTime(2026, 10, 11)));
      expect(png.sublist(1, 4), 'PNG'.codeUnits);
      expect(png.length, greaterThan(1000));
    });

    test('a 403 explains the missing write permission', () async {
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient(
            (request) async => http.Response('{"detail": "forbidden"}', 403)),
      );
      expect(
        twitter.postTweet('hello'),
        throwsA(
            predicate((e) => e.toString().contains('reconnect Twitter'))),
      );
    });
  });
}
