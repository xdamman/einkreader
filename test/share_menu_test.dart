// The reader's share menu (top-right): open in browser, share the article or
// its highlights by email, and — when Twitter is connected — post a tweet.
// Also covers TwitterService.postTweet against a fake API.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
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
