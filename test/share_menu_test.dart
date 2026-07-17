// The reader's share menu (top-right): open in browser, share the article or
// its highlights by email, and — when Twitter is connected — post a tweet.
// Also covers TwitterService.postTweet against a fake API.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/share_actions.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/highlight_list.dart';
import 'package:flutter/material.dart';
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
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_share_menu').path,
        'test.db');

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

  testWidgets('share menu lists browser + email options (no Twitter here)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: articleId),
    ));
    await settle(tester);

    await tester.tap(find.byTooltip('Share'));
    await settle(tester);

    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text('Share article by email'), findsOneWidget);
    expect(find.text('Share highlights by email'), findsOneWidget);
    expect(find.textContaining('1 highlight'), findsOneWidget);
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
    expect(find.text('Share by email'), findsOneWidget);
    expect(find.text('Share…'), findsOneWidget);
    expect(find.text('Share on Twitter'), findsNothing);
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
                quoteTweetId: '123',
                quotePreview: (
                  author: '@someone',
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

    test('a 403 explains the missing write permission', () async {
      final twitter = TwitterService(
        accessToken: () async => 'token',
        client: MockClient(
            (request) async => http.Response('{"detail": "forbidden"}', 403)),
      );
      expect(
        twitter.postTweet('hello'),
        throwsA(predicate(
            (e) => e.toString().contains('Reconnect Twitter in Settings'))),
      );
    });
  });
}
