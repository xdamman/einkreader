// The Read and Highlights tabs break their items down per source with count
// chips (like search facets), and a pending article's meta line says what is
// actually happening: "queued for download" (online), "downloading…" (fetch
// in flight) or "not downloaded" (offline).
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
  late int pendingId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_facets').path,
        'test.db');

    Future<Source> addSource(String title) => db.insertSource(Source(
        type: SourceType.rss,
        title: title,
        url: 'https://$title.example',
        createdAt: 0));
    Future<Article> addArticle(Source source, String name,
        {int read = 0, int fetched = 1}) async {
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'story-$name',
        title: 'Story $name',
        contentMarkdown: fetched == 1 ? 'Body of $name' : null,
        publishedAt: 100,
        createdAt: 100,
        fetched: fetched,
        read: read,
      ));
      return (await db.getArticles())
          .firstWhere((a) => a.guid == 'story-$name');
    }

    final alpha = await addSource('Alpha');
    final beta = await addSource('Beta');
    final a1 = await addArticle(alpha, 'A1', read: 1);
    final pending = await addArticle(alpha, 'A2', fetched: 0);
    pendingId = pending.id!;
    final b1 = await addArticle(beta, 'B1', read: 1);
    await addArticle(beta, 'B2', read: 1);
    await db.insertHighlightIfNew(Highlight(
        articleId: a1.id!, text: 'quote from alpha', createdAt: 100));
    await db.insertHighlightIfNew(Highlight(
        articleId: b1.id!, text: 'quote from beta', createdAt: 200));
  });

  tearDown(() {
    SyncService.instance.lastKnownOffline = false;
    SyncService.instance.downloadingArticleId = null;
  });

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

  testWidgets('Read tab: per-source chips with counts filter the list',
      (tester) async {
    await pumpHome(tester, const ValueKey('read-facets'));
    await tester.tap(find.text('Read'));
    await settle(tester);

    // Both sources' read stories under All; chips carry their counts.
    expect(find.text('Story A1'), findsOneWidget);
    expect(find.text('Story B1'), findsOneWidget);
    expect(find.text('Story B2'), findsOneWidget);
    // Chip 'Beta' (first match) + the two tiles' meta lines.
    expect(find.text('Beta'), findsNWidgets(3));

    await tester.tap(find.text('Beta').first);
    await settle(tester);
    expect(find.text('Story A1'), findsNothing);
    expect(find.text('Story B1'), findsOneWidget);
    expect(find.text('Story B2'), findsOneWidget);

    await tester.tap(find.text('All').last);
    await settle(tester);
    expect(find.text('Story A1'), findsOneWidget);
  });

  testWidgets('Highlights tab: per-source chips filter the highlights',
      (tester) async {
    await pumpHome(tester, const ValueKey('highlight-facets'));
    await tester.tap(find.text('Highlights'));
    await settle(tester);

    expect(find.text('quote from alpha'), findsOneWidget);
    expect(find.text('quote from beta'), findsOneWidget);

    await tester.tap(find.text('Alpha').first);
    await settle(tester);
    expect(find.text('quote from alpha'), findsOneWidget);
    expect(find.text('quote from beta'), findsNothing);

    await tester.tap(find.text('All'));
    await settle(tester);
    expect(find.text('quote from beta'), findsOneWidget);
  });

  testWidgets('a pending article reads "queued for download" when online',
      (tester) async {
    await pumpHome(tester, const ValueKey('status-queued'));
    expect(find.textContaining('queued for download'), findsOneWidget);
    expect(find.textContaining('not downloaded'), findsNothing);
  });

  testWidgets('a pending article reads "downloading…" while being fetched',
      (tester) async {
    SyncService.instance.downloadingArticleId = pendingId;
    await pumpHome(tester, const ValueKey('status-downloading'));
    expect(find.textContaining('downloading…'), findsOneWidget);
  });

  testWidgets('a pending article reads "not downloaded" only when offline',
      (tester) async {
    SyncService.instance.lastKnownOffline = true;
    await pumpHome(tester, const ValueKey('status-offline'));
    expect(find.textContaining('not downloaded'), findsOneWidget);
    expect(find.textContaining('queued'), findsNothing);
  });
}
