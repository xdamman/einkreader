// Settings → Reading: text size, font, margins and paged reading, persisted
// and followed by the article screen ("Page 2 / 5" with arrows).
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/screens/settings_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/reading_settings.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:einkreader/widgets/page_breaks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  final settings = ReadingSettings.instance;
  late int longId;
  late int shortId;
  late int proseId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_readset').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath: Directory.systemTemp.createTempSync('einkreader_rs_arch').path);
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    final long = List.generate(
            60, (i) => 'Paragraph $i with enough words to take up a line.')
        .join('\n\n');
    final prose = List.generate(
        30,
        (i) => List.filled(3 + i % 7,
                'Sentence $i runs long enough to wrap the column again.')
            .join(' ')).join('\n\n');
    for (final (title, body) in [
      ('Long', long),
      ('Short', 'One line.'),
      ('Prose', prose),
    ]) {
      await db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: title,
          title: title,
          contentMarkdown: body,
          publishedAt: 1,
          createdAt: 1,
          fetched: 1));
    }
    final all = await db.getArticles();
    longId = all.firstWhere((a) => a.title == 'Long').id!;
    shortId = all.firstWhere((a) => a.title == 'Short').id!;
    proseId = all.firstWhere((a) => a.title == 'Prose').id!;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings.debugReset();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  test('preferences persist and reload', () async {
    await settings.update(const ReadingPrefs(
        fontSize: 22,
        font: ReadingFont.literata,
        margin: 64,
        paginated: true));
    settings.debugReset();
    final loaded = await settings.load();
    expect(loaded, const ReadingPrefs(
        fontSize: 22, font: ReadingFont.literata, margin: 64, paginated: true));
    await settings.update(loaded.copyWith(margin: () => null));
    settings.debugReset();
    expect((await settings.load()).margin, isNull);
  });

  test('margins: automatic column on tablets, never squeezing the text', () {
    const auto = ReadingPrefs();
    expect(auto.marginFor(400), 20);
    expect(auto.marginFor(1080), 200);
    expect(const ReadingPrefs(margin: 40).marginFor(1080), 40);
    expect(const ReadingPrefs(margin: 200).marginFor(400), 80,
        reason: 'at least 240px of text remain');
  });

  testWidgets('About & contact gives an email address (Play requires it)',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const SettingsScreen()));
    await settle(tester);
    await tester.tap(find.text('About & contact'));
    await settle(tester);
    expect(find.text('Contact: einkreader@collective.email'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
  });

  testWidgets('the Reading section changes font, margins and paging',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const SettingsScreen()));
    await settle(tester);
    expect(find.text('Reading'), findsOneWidget);
    await tester.tap(find.text('Reading'));
    await settle(tester);

    expect(find.byKey(const Key('readingPreview')), findsOneWidget);
    expect(find.text('Margins: automatic'), findsOneWidget);

    await tester.tap(find.text('Literata'));
    await settle(tester);
    expect(settings.prefs.value.font, ReadingFont.literata);

    // Dragging the margin slider sets an explicit margin.
    await tester.drag(find.byType(Slider).last, const Offset(-300, 0));
    await settle(tester);
    expect(settings.prefs.value.margin, isNotNull);
    await tester.tap(find.text('Use automatic'));
    await settle(tester);
    expect(settings.prefs.value.margin, isNull);

    await tester.tap(find.text('Turn pages instead of scrolling'));
    await settle(tester);
    expect(settings.prefs.value.paginated, isTrue);
    final saved = await tester.runAsync(SharedPreferences.getInstance);
    expect(saved!.getBool('reading_paginated'), isTrue);
  });

  Future<void> openArticle(WidgetTester tester, int id) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: ArticleScreen(articleId: id)));
    await settle(tester);
  }

  testWidgets('the article uses the chosen font and margins', (tester) async {
    await settings.update(
        const ReadingPrefs(font: ReadingFont.hyperlegible, margin: 48));
    await openArticle(tester, longId);
    final view = tester.widget<MarkdownView>(find.byType(MarkdownView));
    expect(view.fontFamily, 'Atkinson Hyperlegible');
    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect((scroll.padding as EdgeInsets).left, 48);
    expect(find.text('Page 1 / 2'), findsNothing,
        reason: 'no page bar while scrolling');
  });

  testWidgets('paged: page indicator with arrows only where useful',
      (tester) async {
    await settings.update(const ReadingPrefs(paginated: true));
    await openArticle(tester, longId);

    final bar = find.textContaining(RegExp(r'^Page \d+ / \d+$'));
    expect(bar, findsOneWidget);
    final count =
        int.parse(RegExp(r'/ (\d+)').firstMatch(tester.widget<Text>(bar).data!)!
            .group(1)!);
    expect(count, greaterThan(2));
    expect(find.text('Page 1 / $count'), findsOneWidget);
    expect(find.byTooltip('Previous page'), findsNothing);
    expect(find.byTooltip('Next page'), findsOneWidget);

    await tester.tap(find.byTooltip('Next page'));
    await settle(tester);
    expect(find.text('Page 2 / $count'), findsOneWidget);
    expect(find.byTooltip('Previous page'), findsOneWidget);
    expect(find.byTooltip('Next page'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous page'));
    await settle(tester);
    expect(find.text('Page 1 / $count'), findsOneWidget);

    for (var i = 1; i < count; i++) {
      await tester.tap(find.byTooltip('Next page'));
      await settle(tester);
    }
    expect(find.text('Page $count / $count'), findsOneWidget);
    expect(find.byTooltip('Next page'), findsNothing);
    final article = await tester.runAsync(() => db.getArticle(longId));
    expect(article!.read, 1, reason: 'the last page is the end: read');
  });

  testWidgets('paged: a swipe up turns the page; text does not scroll',
      (tester) async {
    await settings.update(const ReadingPrefs(paginated: true));
    await openArticle(tester, longId);
    expect(find.textContaining(RegExp(r'^Page 1 / ')), findsOneWidget);
    await tester.fling(
        find.byKey(const Key('articleSwipe')), const Offset(0, -300), 1500);
    await settle(tester);
    expect(find.textContaining(RegExp(r'^Page 2 / ')), findsOneWidget);
  });

  testWidgets('paged: no page shows a cut line, top or bottom',
      (tester) async {
    await settings.update(const ReadingPrefs(paginated: true));
    await openArticle(tester, proseId);
    final bar = find.textContaining(RegExp(r'^Page \d+ / \d+$'));
    final count = int.parse(RegExp(r'/ (\d+)')
        .firstMatch(tester.widget<Text>(bar).data!)!
        .group(1)!);
    expect(count, greaterThan(2));
    for (var page = 1; page <= count; page++) {
      final view = tester.renderObject<RenderBox>(find.byType(Scrollable));
      final column = tester.renderObject(find.byType(MarkdownView));
      // Lines relative to the screen's top; the cover hides what's below.
      final lines = collectLines(column, view, 0).expand((p) => p).toList();
      expect(lines, isNotEmpty);
      final cover = find.byType(Positioned);
      final bottom = cover.evaluate().isEmpty
          ? view.size.height
          : tester.widget<Positioned>(cover).top!;
      for (final (top, end) in lines) {
        expect(top < -0.5 && end > 0.5, isFalse,
            reason: 'page $page cuts a line at the top ($top–$end)');
        expect(top < bottom - 0.5 && end > bottom + 0.5, isFalse,
            reason: 'page $page cuts a line at the bottom ($top–$end)');
      }
      if (page < count) {
        await tester.tap(find.byTooltip('Next page'));
        await settle(tester);
      }
    }
  });

  testWidgets('paged: a short article has no page bar', (tester) async {
    await settings.update(const ReadingPrefs(paginated: true));
    await openArticle(tester, shortId);
    expect(find.textContaining(RegExp(r'^Page ')), findsNothing);
  });
}
