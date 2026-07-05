// Reading-progress lifecycle:
//   open           -> stays unread (no more mark-read-on-open)
//   scroll down    -> "reading": position saved, article shows under Resume
//   reopen         -> scroll position restored
//   reach bottom   -> read, position cleared
//   back to top    -> reset to unread (position cleared) if bottom never seen
//   fits on screen -> read immediately (its bottom is visible on open)
// Plus the Resume reading section's swipe/bookmark actions.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/resume_reading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Map<String, int> idsByTitle;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Private db path so this file can't race other test files on the shared
    // default ffi databases directory.
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_reading').path,
        'test.db');

    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    final long = List.generate(
        80, (i) => 'Paragraph $i with enough words to take up a line or two.')
        .join('\n\n');
    idsByTitle = {};
    for (final spec in [
      ('Long A', long),
      ('Long B', long),
      ('Short', 'One line.'),
      ('Resume 1', long),
      ('Resume 2', long),
      ('Resume 3', long),
    ]) {
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'guid-${spec.$1}',
        title: spec.$1,
        contentMarkdown: spec.$2,
        publishedAt: 100,
        createdAt: 100,
        fetched: 1,
      ));
    }
    for (final a in await db.getArticles()) {
      idsByTitle[a.title] = a.id!;
    }
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<Article> article(WidgetTester tester, String title) async =>
      (await tester.runAsync(() => db.getArticle(idsByTitle[title]!)))!;

  Future<void> openArticle(WidgetTester tester, String title) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: idsByTitle[title]!),
    ));
    await settle(tester);
  }

  ScrollPosition scrollPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  testWidgets('scrolling starts reading, bottom marks read, reopen resumes',
      (tester) async {
    await openArticle(tester, 'Long A');
    var a = await article(tester, 'Long A');
    expect(a.read, 0, reason: 'opening alone no longer marks read');
    expect(a.scrollPosition, 0);

    // Scroll down: the article becomes "reading" with its position saved.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -600));
    await settle(tester);
    a = await article(tester, 'Long A');
    expect(a.read, 0);
    expect(a.scrollPosition, greaterThan(100));
    expect(ResumeReadingSection.currentReads([a]), [a]);

    // Reopen: reading resumes from the saved position.
    await tester.pumpWidget(const SizedBox.shrink());
    await openArticle(tester, 'Long A');
    expect(scrollPosition(tester).pixels, greaterThan(100));

    // Reaching the bottom marks it read and clears the position.
    scrollPosition(tester).jumpTo(scrollPosition(tester).maxScrollExtent);
    await settle(tester);
    a = await article(tester, 'Long A');
    expect(a.read, 1);
    expect(a.scrollPosition, 0);
    expect(ResumeReadingSection.currentReads([a]), isEmpty);
  });

  testWidgets('scrolling back to the top before the bottom resets to unread',
      (tester) async {
    await openArticle(tester, 'Long B');
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -600));
    await settle(tester);
    expect((await article(tester, 'Long B')).scrollPosition, greaterThan(100));

    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, 700));
    await settle(tester);
    final a = await article(tester, 'Long B');
    expect(a.read, 0);
    expect(a.scrollPosition, 0);
  });

  testWidgets('an article that fits on one screen is read on open',
      (tester) async {
    await openArticle(tester, 'Short');
    expect((await article(tester, 'Short')).read, 1);
  });

  testWidgets('resume section: swipe right reads, swipe left unreads, '
      'bookmark saves for later', (tester) async {
    for (final title in ['Resume 1', 'Resume 2', 'Resume 3']) {
      await db.saveScrollPosition(idsByTitle[title]!, 300);
    }
    var shown = ResumeReadingSection.currentReads(await db.getArticles());
    expect(shown, hasLength(3));

    late StateSetter refresh;
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          refresh = setState;
          return ResumeReadingSection(
            articles: shown,
            // The real home screen re-queries; here dismissed rows are removed
            // synchronously so the Dismissible leaves the tree right away.
            onChanged: () {},
          );
        }),
      ),
    ));
    await settle(tester);

    // Swipes: let confirmDismiss finish its db write (real async, so flushed
    // via runAsync), let the slide-out complete, then drop the row like the
    // home screen's reload would.
    Future<void> dismissTopRow(WidgetTester tester,
        {required bool toRight}) async {
      await tester.drag(find.text(shown.first.displayTitle).first,
          Offset(toRight ? 600 : -600, 0));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 250));
      refresh(() => shown = shown.sublist(1));
      await tester.pump();
    }

    // Swipe right → mark as read.
    final readTitle = shown.first.title;
    await dismissTopRow(tester, toRight: true);
    var a = await article(tester, readTitle);
    expect(a.read, 1);
    expect(a.scrollPosition, 0);

    // Swipe left → back to unread, progress dropped.
    final unreadTitle = shown.first.title;
    await dismissTopRow(tester, toRight: false);
    a = await article(tester, unreadTitle);
    expect(a.read, 0);
    expect(a.scrollPosition, 0);

    // Bookmark → moved to To Read, out of Resume reading.
    final savedTitle = shown.first.title;
    await tester.tap(find.byTooltip('Read later'));
    await settle(tester);
    a = await article(tester, savedTitle);
    expect(a.readLater, 1);
    expect(ResumeReadingSection.currentReads([a]), isEmpty);
  });
}
