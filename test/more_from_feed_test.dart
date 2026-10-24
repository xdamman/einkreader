// "More from this feed" at the end of an article: the feed's five latest
// other unread articles, newest first, one tap away.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
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
  late int openId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_more').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_more_arch').path);

    final blog = await db.insertSource(Source(
        type: SourceType.rss, title: 'Blog', url: 'https://blog', createdAt: 0));
    final other = await db.insertSource(Source(
        type: SourceType.rss, title: 'Other', url: 'https://o', createdAt: 0));
    Future<void> add(int sourceId, String guid, int at, {int read = 0}) =>
        db.insertArticleIfNew(Article(
          sourceId: sourceId,
          guid: guid,
          title: guid,
          contentMarkdown: 'Body of $guid',
          publishedAt: at,
          createdAt: at,
          fetched: 1,
          read: read,
        ));
    await add(blog.id!, 'open', 50);
    for (var i = 1; i <= 7; i++) {
      await add(blog.id!, 'story $i', 100 + i);
    }
    await add(blog.id!, 'already read', 200, read: 1);
    await add(other.id!, 'elsewhere', 300);
    openId =
        (await db.getArticles()).firstWhere((a) => a.guid == 'open').id!;
  });

  // Opening an article reads it: start every test with the stories unread.
  setUp(() async {
    for (final a in await db.getArticles()) {
      if (a.guid.startsWith('story')) {
        await db.markArticleRead(a.id!, read: false);
      }
    }
  });

  test('newest five unread of the same feed, without the open one', () async {
    final more = await db.getUnreadFromSource(
        (await db.getArticle(openId))!.sourceId,
        exceptId: openId);
    expect([for (final a in more) a.title],
        ['story 7', 'story 6', 'story 5', 'story 4', 'story 3']);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: ArticleScreen(articleId: openId)));
    await settle(tester);
  }

  testWidgets('up next, then the others, with dates; a tap opens one',
      (tester) async {
    await open(tester);
    // The newest is up next; the others are also unread.
    expect(find.text('UP NEXT IN BLOG'), findsOneWidget);
    expect(find.text('ALSO UNREAD'), findsOneWidget);
    for (var i = 3; i <= 7; i++) {
      expect(find.text('story $i'), findsOneWidget);
    }
    expect(find.text('story 2'), findsNothing);
    expect(find.text('already read'), findsNothing);
    expect(find.text('elsewhere'), findsNothing);
    // Every listed article shows its date.
    expect(find.textContaining('Jan 1, 1970'), findsNWidgets(5));
    // The feedback link sits on its own line, after the question.
    expect(
        find.textContaining('How was your reading experience?\n'
            'Leave a feedback',
            findRichText: true),
        findsOneWidget);

    await tester.tap(find.text('story 5'));
    await settle(tester);
    expect(find.text('Body of story 5'), findsOneWidget);
  });

  testWidgets('"Read next" opens the newest unread', (tester) async {
    await open(tester);
    await tester.tap(find.text('Read next'));
    await settle(tester);
    expect(find.text('Body of story 7'), findsOneWidget);
  });

  testWidgets('"See all" opens the feed when more are unread', (tester) async {
    await open(tester);
    await tester.tap(find.text('See all 7 unread ›'));
    await settle(tester);
    expect(find.text('story 1'), findsOneWidget);
  });
}
