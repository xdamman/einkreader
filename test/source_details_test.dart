// Sources screen details:
//   - the feed's own description (RSS <description> / Atom <subtitle>) is
//     parsed, stored and shown on the source row
//   - each row shows stats: downloaded articles, content size, read count,
//     highlights
//   - the ⋮ menu lists move destinations directly (one click)
//   - a source can be dragged onto a folder row (long-press drag)
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/sources_screen.dart';
import 'package:einkreader/services/feed_parser.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Folder news;
  late Source local;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_source_details').path,
        'test.db');

    news = await db.insertFolder('News');
    local = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Local Paper',
        url: 'https://local.example/feed',
        createdAt: 0));
    await db.updateSourceDescription(
        local.id!, 'All the local news that fits');
    // Two articles: one read and downloaded with content, one still pending.
    await db.insertArticleIfNew(Article(
      sourceId: local.id!,
      guid: 'a1',
      title: 'Read Story',
      contentMarkdown: 'x' * 2048,
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
      read: 1,
    ));
    await db.insertArticleIfNew(Article(
      sourceId: local.id!,
      guid: 'a2',
      title: 'Pending Story',
      publishedAt: 90,
      createdAt: 90,
    ));
    final readStory = (await db.getArticles(sourceId: local.id))
        .firstWhere((a) => a.guid == 'a1');
    await db.insertHighlight(Highlight(
        articleId: readStory.id!, text: 'a passage', createdAt: 1));
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  group('FeedParser descriptions', () {
    test('RSS channel description, HTML stripped', () {
      final feed = FeedParser.parse('''
        <rss version="2.0"><channel>
          <title>Paper</title>
          <description>&lt;p&gt;All the   local news&lt;/p&gt;</description>
        </channel></rss>
      ''');
      expect(feed.description, 'All the local news');
    });

    test('Atom subtitle', () {
      final feed = FeedParser.parse('''
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Paper</title><subtitle>Daily digest</subtitle>
        </feed>
      ''');
      expect(feed.description, 'Daily digest');
    });

    test('absent description is null', () {
      final feed = FeedParser.parse(
          '<rss version="2.0"><channel><title>T</title></channel></rss>');
      expect(feed.description, isNull);
    });
  });

  test('sourceStats aggregates downloads, reads, size and highlights',
      () async {
    final stats = (await db.sourceStats())[local.id]!;
    expect(stats.downloaded, 1);
    expect(stats.read, 1);
    expect(stats.contentBytes, 2048);
    expect(stats.highlights, 1);
  });

  testWidgets('source row shows description, stats and a one-click move menu',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const SourcesScreen(),
    ));
    await settle(tester);

    expect(find.text('All the local news that fits'), findsOneWidget);
    expect(find.text('1 article · 2 KB · 1 read · 1 highlight'),
        findsOneWidget);

    // The options menu lists the folder directly.
    await tester.tap(find.byTooltip('Source options'));
    await settle(tester);
    expect(find.text('Move to "News"'), findsOneWidget);
    await tester.tap(find.text('Move to "News"'));
    await settle(tester);
    var moved = (await tester.runAsync(() => db.getSources()))!
        .firstWhere((s) => s.id == local.id);
    expect(moved.folderId, news.id);
    // Now inside the folder, the menu offers the way back out.
    await tester.tap(find.byTooltip('Source options'));
    await settle(tester);
    await tester.tap(find.text('Move to top level'));
    await settle(tester);
    moved = (await tester.runAsync(() => db.getSources()))!
        .firstWhere((s) => s.id == local.id);
    expect(moved.folderId, isNull);
  });

  testWidgets('dragging a source onto a folder files it there',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const SourcesScreen(),
    ));
    await settle(tester);

    final gesture = await tester
        .startGesture(tester.getCenter(find.text('Local Paper')));
    await tester.pump(const Duration(milliseconds: 700)); // long-press
    await gesture.moveTo(tester.getCenter(find.text('News')));
    await tester.pump();
    await gesture.up();
    await settle(tester);

    final moved = (await tester.runAsync(() => db.getSources()))!
        .firstWhere((s) => s.id == local.id);
    expect(moved.folderId, news.id);
  });
}
