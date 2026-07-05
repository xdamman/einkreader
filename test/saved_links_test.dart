// Covers the in-article link flow and its rendering fixes:
//   - \[ \] escapes from html2md render as literal brackets
//   - image alt text is no longer shown as a caption below the image
//   - tapping a link offers "Open in browser" + "Read later" online, and only
//     "Read later" offline
//   - "Read later" queues the page (fetched = 0, bookmarked) under the
//     built-in Saved Links source with a reference to the origin article,
//     shown as a "From: …" link in the saved article's header
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late int originId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_links').path,
        'test.db');

    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'origin',
      title: 'The Origin Story',
      contentMarkdown: [
        'Intro paragraph mentioning [a great essay](https://example.org/essay) '
            'worth reading.',
        for (var i = 0; i < 40; i++) 'Padding paragraph $i.',
      ].join('\n\n'),
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
    ));
    originId = (await db.getArticles()).single.id!;
  });

  tearDown(() => SyncService.instance.debugIsOnline = null);

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  String renderedText(WidgetTester tester) {
    final out = StringBuffer();
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text != null) out.write(span.text);
        (span.children ?? const <InlineSpan>[]).forEach(walk);
      }
    }

    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(rich.text);
    }
    return out.toString();
  }

  /// Fires the tap recognizer of the span whose text is [anchor].
  void tapLink(WidgetTester tester, String anchor) {
    TapGestureRecognizer? found;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text == anchor && span.recognizer is TapGestureRecognizer) {
          found = span.recognizer as TapGestureRecognizer;
        }
        (span.children ?? const <InlineSpan>[]).forEach(walk);
      }
    }

    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(rich.text);
    }
    expect(found, isNotNull, reason: 'no link span "$anchor"');
    found!.onTap!();
  }

  testWidgets(r'renders \[ and \] as literal brackets', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'A study \\[Smith 2024\\] found *very \\[odd\\]* things.\n\n'
              '# About \\[brackets\\]\n\nCode keeps escapes: `a\\[b`',
        ),
      ),
    ));
    final text = renderedText(tester);
    expect(text, contains('[Smith 2024]'));
    expect(text, contains('very [odd]'));
    expect(text, contains('About [brackets]'));
    expect(text, contains(r'a\[b'), reason: 'inline code stays literal');
    expect(text, isNot(contains(r'\[Smith')));
  });

  testWidgets('image alt text is not shown as a caption', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(
          markdown: 'Before.\n\n![IMG_1234.jpg](https://example.org/i.png)\n\n'
              'After.',
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('IMG_1234.jpg'), findsNothing);
  });

  testWidgets('offline link tap offers Read later only and queues the page',
      (tester) async {
    SyncService.instance.debugIsOnline = () async => false;
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: originId),
    ));
    await settle(tester);

    tapLink(tester, 'a great essay');
    await settle(tester);
    expect(find.text('Open in browser'), findsNothing);
    expect(find.text('Read later'), findsOneWidget);

    await tester.tap(find.text('Read later'));
    await settle(tester);
    expect(find.textContaining('will download when back online'),
        findsOneWidget);

    final saved = (await tester.runAsync(() => db.getArticles()))!
        .firstWhere((a) => a.url == 'https://example.org/essay');
    expect(saved.readLater, 1);
    expect(saved.fetched, 0, reason: 'queued for the next online sync');
    expect(saved.read, 0);
    expect(saved.viaArticleId, originId);
    expect(saved.title, 'a great essay');
    final linkSource =
        (await tester.runAsync(() => db.getSource(saved.sourceId)))!;
    expect(linkSource.type, SourceType.savedLinks);

    // Saving the same link again just bookmarks the existing row.
    final again = (await tester.runAsync(() => db.saveLinkForLater(
        url: 'https://example.org/essay?utm_source=feed',
        viaArticleId: originId)))!;
    expect(again.id, saved.id);
  });

  testWidgets('online link tap also offers Open in browser', (tester) async {
    SyncService.instance.debugIsOnline = () async => true;
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: originId),
    ));
    await settle(tester);

    tapLink(tester, 'a great essay');
    await settle(tester);
    expect(find.text('Open in browser'), findsOneWidget);
    expect(find.text('Read later'), findsOneWidget);
    // Close without choosing.
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
  });

  testWidgets('a saved link shows "From: …" linking back to the origin',
      (tester) async {
    final saved = (await db.getArticles())
        .firstWhere((a) => a.url == 'https://example.org/essay');
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(articleId: saved.id!),
    ));
    await settle(tester);

    expect(find.text('From: The Origin Story'), findsOneWidget);
    await tester.tap(find.text('From: The Origin Story'));
    await settle(tester);
    // The origin article opened.
    expect(find.text('The Origin Story'), findsWidgets);
    expect(find.textContaining('Intro paragraph', findRichText: true),
        findsOneWidget);
  });
}
