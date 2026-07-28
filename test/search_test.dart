// Universal search over everything the reader stores:
//   - db.search matches authors, titles, content, highlight text/comments and
//     source titles; multi-term AND; LIKE wildcards are escaped
//   - ranking: highlights first, title hits above content-only hits
//   - the SearchScreen renders highlights above articles, filters by status
//     and by source chip (alphabetical, with counts), and an unread result row
//     swipes right to mark read while staying on screen
//   - tapping a highlight opens its article
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/screens/search_screen.dart';
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
  late Source bx1, aardvark;
  final byTitle = <String, Article>{};

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_search');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));

    bx1 = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'BX1',
        url: 'https://bx1.example',
        createdAt: 0));
    aardvark = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Aardvark',
        url: 'https://aardvark.example',
        createdAt: 0));

    var clock = 100;
    Future<void> add(
      Source source,
      String title, {
      String? author,
      String? content,
      int read = 0,
    }) async {
      clock += 10;
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'guid-$title',
        title: title,
        author: author,
        contentMarkdown: content,
        read: read,
        publishedAt: clock,
        createdAt: clock,
        fetched: 1,
      ));
    }

    await add(bx1, 'Crypto rally today'); // title hit, unread
    await add(bx1, 'Markets update',
        content: 'a long piece about crypto and defi'); // content-only, unread
    await add(bx1, 'Old news', content: 'crypto winter', read: 1); // read
    await add(aardvark, 'Crypto in Belgium'); // title hit, other source
    await add(aardvark, 'Gitcoin grants',
        author: 'owocki', content: 'grants program'); // author hit
    await add(bx1, 'Discount',
        content: '100% crypto returns'); // literal 100% + crypto
    await add(aardvark, 'Plain', content: 'nothing special'); // control

    for (final a in await db.getArticles()) {
      byTitle[a.title] = a;
    }

    await db.insertHighlight(Highlight(
        articleId: byTitle['Crypto rally today']!.id!,
        text: 'crypto is volatile',
        createdAt: 1000));
    await db.insertHighlight(Highlight(
        articleId: byTitle['Markets update']!.id!,
        text: 'markets move fast',
        comment: 'my crypto note',
        createdAt: 1001));
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  // A tall surface so the whole results list renders (a lazy ListView only
  // builds visible rows, which would hide lower-ranked matches).
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350)); // fire the debounce
    await settle(tester);
    await settle(tester);
  }

  // ------------------------------------------------------------------ db

  test('search matches every field, ANDs terms, and escapes wildcards',
      () async {
    // Author.
    final byAuthor = await db.search('owocki');
    expect(byAuthor.articles.map((a) => a.title), contains('Gitcoin grants'));

    // Title.
    expect((await db.search('rally')).articles.map((a) => a.title),
        contains('Crypto rally today'));

    // Content.
    expect((await db.search('defi')).articles.map((a) => a.title),
        contains('Markets update'));

    // Highlight text and comment.
    final byText = await db.search('volatile');
    expect(byText.highlights, hasLength(1));
    expect(byText.highlights.single.text, 'crypto is volatile');
    final byComment = await db.search('note');
    expect(byComment.highlights, hasLength(1));
    expect(byComment.highlights.single.comment, 'my crypto note');

    // Source title.
    expect((await db.search('aardvark')).sources.map((s) => s.title),
        contains('Aardvark'));

    // Multi-term AND: both terms must be present in one row.
    final both = await db.search('crypto belgium');
    expect(both.articles.map((a) => a.title), ['Crypto in Belgium']);

    // Wildcard escaping: "100%" is a literal, not "match everything".
    final literal = await db.search('100%');
    expect(literal.articles.map((a) => a.title), ['Discount']);
  });

  test('ranking: highlights first, title hits above content-only hits',
      () async {
    final results = await db.search('crypto');
    expect(results.highlights, isNotEmpty,
        reason: 'highlights always lead the results');

    final titles = results.articles.map((a) => a.title).toList();
    final firstTitleHit = titles.indexWhere((t) => t.toLowerCase().contains('crypto'));
    final contentOnly = titles.indexOf('Markets update');
    expect(firstTitleHit, 0, reason: 'a title match scores highest');
    expect(firstTitleHit, lessThan(contentOnly),
        reason: 'title hit ranks above a content-only hit');
  });

  // -------------------------------------------------------------- widget

  testWidgets('highlights render above articles; status and source chips filter',
      (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const SearchScreen()));
    await settle(tester);
    // Before typing: the intro message.
    expect(find.textContaining('Search your whole library'), findsOneWidget);

    await typeQuery(tester, 'crypto');

    // Highlight result and article result both present…
    expect(find.text('crypto is volatile'), findsOneWidget);
    expect(find.text('Crypto rally today'), findsOneWidget);
    // …with the Highlights group above the Articles group.
    expect(tester.getTopLeft(find.text('HIGHLIGHTS')).dy,
        lessThan(tester.getTopLeft(find.text('ARTICLES')).dy));

    // Source chips: alphabetical, each with its match count.
    expect(find.text('Aardvark 1'), findsOneWidget);
    expect(find.text('BX1 4'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Aardvark 1')).dx,
        lessThan(tester.getTopLeft(find.text('BX1 4')).dx));

    // Status: Unread hides the read article.
    expect(find.text('Old news'), findsOneWidget);
    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();
    expect(find.text('Old news'), findsNothing);
    expect(find.text('Crypto rally today'), findsOneWidget);

    // Back to All, then filter by the BX1 source chip.
    await tester.tap(find.text('All').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('BX1 4'));
    await tester.pumpAndSettle();
    expect(find.text('Crypto in Belgium'), findsNothing); // Aardvark article
    expect(find.text('Crypto rally today'), findsOneWidget); // BX1 article
  });

  testWidgets('swiping an unread result row right marks it read, row stays',
      (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const SearchScreen()));
    await settle(tester);
    await typeQuery(tester, 'crypto');

    final id = byTitle['Crypto rally today']!.id!;
    expect((await tester.runAsync(() => db.getArticle(id)))!.read, 0);

    await tester.drag(find.text('Crypto rally today'), const Offset(900, 0));
    await settle(tester);
    await settle(tester);

    expect((await tester.runAsync(() => db.getArticle(id)))!.read, 1,
        reason: 'swipe right marks read, same as the feed');
    expect(find.text('Crypto rally today'), findsOneWidget,
        reason: 'the row stays, re-rendered as read');

    // Restore for any later assertions.
    await tester.runAsync(() => db.markArticleRead(id, read: false));
  });

  testWidgets('tapping a highlight result opens its article', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const SearchScreen()));
    await settle(tester);
    await typeQuery(tester, 'crypto');

    await tester.tap(find.text('crypto is volatile'));
    await settle(tester);
    await settle(tester);

    expect(find.byType(ArticleScreen), findsOneWidget);
    expect(find.text('Crypto rally today'), findsWidgets);
  });
}
