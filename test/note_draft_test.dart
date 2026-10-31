// A note typed in the note/share overlay survives closing it by mistake:
// reopening on the same highlight restores the draft; saving clears it.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/share_note_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Article article;
  late Highlight highlight;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_draft');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'a1',
      title: 'Story',
      contentMarkdown: 'a passage worth keeping',
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
    ));
    article = (await db.getArticles()).single;
    await db.insertHighlight(Highlight(
        articleId: article.id!, text: 'a passage worth keeping', createdAt: 1));
    highlight = (await db.getHighlights()).single;
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<void> openNote(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => ShareNoteDialog.open(context,
                article: article, highlight: highlight, shareByDefault: false),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
    await settle(tester);
  }

  Future<void> dismiss(WidgetTester tester) async {
    // Tap outside the overlay — the "closed by mistake" case.
    await tester.tapAt(const Offset(2, 2));
    await settle(tester);
    expect(find.byType(ShareNoteDialog), findsNothing);
  }

  final field = find.widgetWithText(TextField, 'Your note (optional)');

  testWidgets('draft survives dismissal; discard and save clear it',
      (tester) async {
    await openNote(tester);
    expect(find.text('Discard draft'), findsNothing);
    await tester.enterText(field, 'half a thought');
    await settle(tester);
    await dismiss(tester);

    // Reopen: the draft is back, flagged as unsaved.
    await openNote(tester);
    expect(find.text('half a thought'), findsOneWidget);
    expect(find.text('Draft restored — not saved yet'), findsOneWidget);

    // Discard: back to the (empty) saved note, and it stays gone.
    await tester.tap(find.text('Discard draft'));
    await settle(tester);
    expect(find.text('half a thought'), findsNothing);
    await dismiss(tester);
    await openNote(tester);
    expect(find.text('Discard draft'), findsNothing);

    // Type, save: the note is stored and no draft lingers.
    await tester.enterText(field, 'a full thought');
    await settle(tester);
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await settle(tester);
    final saved = (await tester.runAsync(() => db.getHighlights()))!.single;
    expect(saved.comment, 'a full thought');
    final key = NoteDrafts.keyFor(article, [highlight]);
    expect(await tester.runAsync(() => NoteDrafts.load(key)), isNull);
  });
}
