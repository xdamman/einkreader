// A source whose last refresh failed (e.g. an expired Twitter session) gets
// a warning icon on its feed chip, and selecting it shows the error above
// its articles — with a "Reconnect Twitter" button for Twitter sources.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late int twitterId;
  late int rssId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_srcerr').path,
        'test.db');

    final twitter = await db.insertSource(Source(
        type: SourceType.twitterBookmarks,
        title: 'Bookmarks',
        url: 'ada',
        createdAt: 0));
    twitterId = twitter.id!;
    final rss = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Alpha',
        url: 'https://alpha.example',
        createdAt: 0));
    rssId = rss.id!;
    for (final source in [twitter, rss]) {
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'story-${source.title}',
        title: 'Story from ${source.title}',
        contentMarkdown: 'Body',
        publishedAt: 100,
        createdAt: 100,
        fetched: 1,
      ));
    }
  });

  tearDown(() => SyncService.instance.sourceErrors.clear());

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<void> pumpHome(WidgetTester tester, Key key) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: HomeScreen(key: key),
    ));
    await settle(tester);
  }

  testWidgets(
      'a failed Twitter source shows a warning chip and a reconnect banner',
      (tester) async {
    SyncService.instance.sourceErrors[twitterId] =
        'Twitter session expired, please reconnect';
    await pumpHome(tester, const ValueKey('twitter-error'));

    // The chip strip flags the source before it is even selected.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('session expired'), findsNothing,
        reason: 'the message itself waits until the source is opened');

    // .first: the chip; the title also appears in the article's meta line.
    await tester.tap(find.text('Bookmarks').first);
    await settle(tester);
    expect(
        find.textContaining('This source could not refresh: '
            'Twitter session expired'),
        findsOneWidget);
    expect(find.text('Reconnect Twitter'), findsOneWidget);
    // The feed itself still shows underneath the banner.
    expect(find.text('Story from Bookmarks'), findsOneWidget);
  });

  testWidgets(
      'a non-auth Twitter error (depleted credits) gets no reconnect button',
      (tester) async {
    SyncService.instance.sourceErrors[twitterId] =
        "Twitter's monthly API credits are used up — this will work again "
        'once the X API plan renews';
    await pumpHome(tester, const ValueKey('twitter-credits'));

    await tester.tap(find.text('Bookmarks').first);
    await settle(tester);
    expect(find.textContaining('API credits are used up'), findsOneWidget);
    expect(find.text('Reconnect Twitter'), findsNothing,
        reason: 'reconnecting cannot fix a billing problem');
  });

  testWidgets('a failed RSS source shows the error but no reconnect button',
      (tester) async {
    SyncService.instance.sourceErrors[rssId] = 'HTTP 500';
    await pumpHome(tester, const ValueKey('rss-error'));

    await tester.tap(find.text('Alpha').first);
    await settle(tester);
    expect(find.textContaining('This source could not refresh: HTTP 500'),
        findsOneWidget);
    expect(find.text('Reconnect Twitter'), findsNothing);
  });

  testWidgets('a healthy strip shows no warning icons', (tester) async {
    await pumpHome(tester, const ValueKey('no-errors'));
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('an outbox tweet refused for auth offers Reconnect Twitter',
      (tester) async {
    await tester.runAsync(() => OutboxService.instance.enqueueTweet(
        'a highlight worth sharing',
        error: 'Exception: Twitter refused the post — reconnect Twitter to '
            'grant the posting permission'));
    await pumpHome(tester, const ValueKey('outbox-reconnect'));

    await tester.tap(find.byIcon(Icons.outbox_outlined));
    await settle(tester);
    await settle(tester);
    expect(find.text('Reconnect Twitter'), findsOneWidget);
    expect(find.textContaining('Exception:'), findsNothing,
        reason: 'the error reads as a sentence');
    await tester.tap(find.text('Close'));
    await settle(tester);
  });
}
