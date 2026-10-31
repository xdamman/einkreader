// Source chips in the feed strip act on the source in place: long-press
// opens a menu to rename it or move it to another folder (or back to the
// top level), double-tap renames it — no detour through Settings.
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
  late Folder news;
  late Source alpha, gamma;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_chip_actions').path,
        'test.db');

    news = await db.insertFolder('News');
    Future<Source> addSource(String title, {int? folderId}) async {
      final source = await db.insertSource(Source(
          type: SourceType.rss,
          title: title,
          url: 'https://$title.example',
          createdAt: 0));
      if (folderId != null) await db.setSourceFolder(source.id!, folderId);
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'story-$title',
        title: 'Story $title',
        contentMarkdown: 'Body of $title',
        publishedAt: 100,
        createdAt: 100,
        fetched: 1,
      ));
      return source;
    }

    alpha = await addSource('Alpha', folderId: news.id);
    await addSource('Beta', folderId: news.id);
    gamma = await addSource('Gamma');
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<Source> reload(Source source) async =>
      (await db.getSources()).firstWhere((s) => s.id == source.id);

  // The chip is the first match; later ones are article tiles' meta lines.
  Finder chip(String label) => find.text(label).first;

  testWidgets('long-press a top-level chip moves it into a folder',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const HomeScreen()));
    await settle(tester);

    await tester.longPress(chip('Gamma'));
    await settle(tester);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move to "News"'), findsOneWidget);
    // Already at the top level: no point offering it.
    expect(find.text('Move to top level'), findsNothing);

    await tester.tap(find.text('Move to "News"'));
    await settle(tester);
    expect((await tester.runAsync(() => reload(gamma)))!.folderId, news.id);

    // Gamma now lives in the folder's row, not the top row.
    await tester.tap(find.text('News'));
    await settle(tester);
    await tester.longPress(chip('Gamma'));
    await settle(tester);
    expect(find.text('Move to "News"'), findsNothing);
    await tester.tap(find.text('Move to top level'));
    await settle(tester);
    expect((await tester.runAsync(() => reload(gamma)))!.folderId, isNull);
  });

  testWidgets('long-press menu and double-tap both rename a source',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const HomeScreen()));
    await settle(tester);

    // Through the menu (Alpha sits in the News folder's second row).
    await tester.tap(find.text('News'));
    await settle(tester);
    await tester.longPress(chip('Alpha'));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    expect(find.text('Rename source'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Alpha Daily');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect((await tester.runAsync(() => reload(alpha)))!.title, 'Alpha Daily');
    expect(find.text('Alpha Daily'), findsWidgets);

    // Double-tap goes straight to the rename dialog.
    final target = chip('Gamma');
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(target);
    await settle(tester);
    expect(find.text('Rename source'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Gamma Weekly');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(
        (await tester.runAsync(() => reload(gamma)))!.title, 'Gamma Weekly');

    // Cancel leaves the name alone.
    await tester.longPress(chip('Gamma Weekly'));
    await settle(tester);
    await tester.tap(find.text('Rename'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Nope');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(
        (await tester.runAsync(() => reload(gamma)))!.title, 'Gamma Weekly');
  });
}
