// "Mark all as seen" on the Feed tab: catching up without pretending to have
// read. Seen articles lose their bold and chip count but stay unread, so the
// Read tab keeps listing only what was actually read.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
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

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_seen').path,
        'test.db');

    for (final name in ['Alpha', 'Beta']) {
      final source = await db.insertSource(Source(
          type: SourceType.rss,
          title: name,
          url: 'https://$name.example',
          createdAt: 0));
      for (var i = 0; i < 2; i++) {
        await db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: '$name-$i',
          title: '$name story $i',
          contentMarkdown: 'Body',
          publishedAt: 100 + i,
          createdAt: 100 + i,
          fetched: 1,
        ));
      }
    }
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<List<Article>> articles(WidgetTester tester) async =>
      (await tester.runAsync(() => db.getArticles()))!;

  testWidgets('marks the selected source as seen, not read, with undo',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const HomeScreen(key: ValueKey('mark-seen')),
    ));
    await settle(tester);
    expect(find.text('4 new articles'), findsOneWidget);

    // Narrowed to Alpha, the action only covers Alpha's stories.
    await tester.tap(find.text('Alpha').first);
    await settle(tester);
    expect(find.text('2 new articles'), findsOneWidget);
    await tester.tap(find.text('Mark all as seen'));
    await settle(tester);

    var all = await articles(tester);
    for (final a in all) {
      final alpha = a.title.startsWith('Alpha');
      expect(a.seenAt != null, alpha, reason: a.title);
      expect(a.read, 0, reason: 'seen is not read: ${a.title}');
    }
    expect(find.text('Mark all as seen'), findsNothing);
    expect(find.text('2 articles marked as seen'), findsOneWidget);

    // Undo brings them back as new.
    await tester.tap(find.text('Undo'));
    await settle(tester);
    all = await articles(tester);
    expect(all.every((a) => a.isNew), isTrue);
    expect(find.text('2 new articles'), findsOneWidget);
  });

  testWidgets('rows shown on screen are recorded as seen on leaving the app',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const HomeScreen(key: ValueKey('auto-seen')),
    ));
    await settle(tester);
    // Still bold during the visit: nothing changes under the reader's eyes.
    expect(find.text('4 new articles'), findsOneWidget);
    expect((await articles(tester)).every((a) => a.isNew), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester);
    final all = await articles(tester);
    expect(all.every((a) => a.seenAt != null && a.read == 0), isTrue);
    // Back in the app: nothing is new any more.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.text('Mark all as seen'), findsNothing);
    await tester.runAsync(
        () => db.markArticlesSeen([for (final a in all) a.id!], seen: false));
  });

  testWidgets('read articles carry a check mark, seen ones do not',
      (tester) async {
    final all = await articles(tester);
    final read = all.firstWhere((a) => a.title == 'Alpha story 0');
    final seen = all.firstWhere((a) => a.title == 'Beta story 0');
    await tester.runAsync(() async {
      await db.markArticleRead(read.id!);
      await db.markArticlesSeen([seen.id!]);
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const HomeScreen(key: ValueKey('three-states')),
    ));
    await settle(tester);
    expect(find.text('Read · Alpha', findRichText: true), findsNothing);
    expect(find.textContaining('Read · Alpha'), findsOneWidget);
    expect(find.textContaining('Read · Beta'), findsNothing);
    FontWeight? weight(String title) =>
        tester.widget<Text>(find.text(title)).style?.fontWeight;
    expect(weight('Alpha story 0'), FontWeight.w400);
    expect(weight('Beta story 0'), FontWeight.w400);
    expect(weight('Beta story 1'), FontWeight.w700);
    await tester.runAsync(() async {
      await db.markArticleRead(read.id!, read: false);
      await db.markArticlesSeen([seen.id!], seen: false);
    });
  });

  test('reading records the seen time too, once', () async {
    final a = (await db.getArticles()).first;
    await db.markArticleRead(a.id!);
    final first = (await db.getArticle(a.id!))!;
    expect(first.seenAt, isNotNull);
    expect(first.seenAt, first.readAt);
    await db.markArticleRead(a.id!, read: false);
  });

  test('marking unread makes a seen article new again', () async {
    final a = (await db.getArticles()).first;
    await db.markArticlesSeen([a.id!]);
    expect((await db.getArticle(a.id!))!.isNew, isFalse);
    await db.markArticleRead(a.id!);
    await db.markArticleRead(a.id!, read: false);
    expect((await db.getArticle(a.id!))!.isNew, isTrue);
  });
}
