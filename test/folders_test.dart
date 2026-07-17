// Folders (one level) for organizing sources:
//   - db: create/rename, move sources in and out, delete with
//     move-to-top-level (default) vs delete-sources-too
//   - feed strip: All, then folders, then top-level sources; a folder chip
//     opens a menu with the whole folder and its member sources
//   - sources screen: add/rename/remove folders, move a source into one
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/screens/sources_screen.dart';
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
  late Source alpha, beta, gamma;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_folders').path,
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
    beta = await addSource('Beta', folderId: news.id);
    gamma = await addSource('Gamma');
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  test('folder crud: rename, membership, delete moves sources up', () async {
    expect((await db.getFolders()).map((f) => f.title), contains('News'));

    final temp = await db.insertFolder('Temp');
    await db.renameFolder(temp.id!, 'Renamed');
    expect((await db.getFolders()).map((f) => f.title), contains('Renamed'));

    // Move a source in, delete the folder: source survives at top level.
    await db.setSourceFolder(gamma.id!, temp.id);
    await db.deleteFolder(temp.id!);
    final sources = await db.getSources();
    final gammaNow = sources.firstWhere((s) => s.id == gamma.id);
    expect(gammaNow.folderId, isNull);
    expect((await db.getFolders()).map((f) => f.title),
        isNot(contains('Renamed')));
  });

  test('deleteFolder(deleteSources: true) removes sources and articles',
      () async {
    final doomed = await db.insertFolder('Doomed');
    final source = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Doomed Feed',
        url: 'https://doomed.example',
        createdAt: 0));
    await db.setSourceFolder(source.id!, doomed.id);
    await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'doomed-story',
        title: 'Doomed Story',
        publishedAt: 100,
        createdAt: 100));

    await db.deleteFolder(doomed.id!, deleteSources: true);
    expect((await db.getSources()).map((s) => s.id), isNot(contains(source.id)));
    expect(await db.getArticles(sourceId: source.id), isEmpty);
  });

  testWidgets('feed strip: All, folder, top-level; folder menu filters',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const HomeScreen(),
    ));
    await settle(tester);

    // All three stories visible under "All"; the folder shows as one chip
    // and its member sources have no top-row chips or second row yet.
    expect(find.text('Story Alpha'), findsOneWidget);
    expect(find.text('Story Gamma'), findsOneWidget);
    expect(find.text('News'), findsOneWidget);
    // Only Story Beta's meta line mentions Beta — no chip for it yet.
    expect(find.text('Beta'), findsOneWidget);

    // One tap selects the folder and reveals its sources as a second chip
    // row below the strip.
    await tester.tap(find.text('News'));
    await settle(tester);
    expect(find.text('Story Alpha'), findsOneWidget);
    expect(find.text('Story Beta'), findsOneWidget);
    expect(find.text('Story Gamma'), findsNothing);
    expect(find.text('Beta'), findsNWidgets(2)); // member chip + tile meta

    // Pick one source in the second row → feed filtered to it. `.first` is
    // the chip; later matches are article tiles' meta lines.
    await tester.tap(find.text('Alpha').first);
    await settle(tester);
    expect(find.text('Story Alpha'), findsOneWidget);
    expect(find.text('Story Beta'), findsNothing);
    expect(find.text('Story Gamma'), findsNothing);

    // Tapping the folder chip again re-selects the whole folder.
    await tester.tap(find.text('News'));
    await settle(tester);
    expect(find.text('Story Alpha'), findsOneWidget);
    expect(find.text('Story Beta'), findsOneWidget);
    expect(find.text('Story Gamma'), findsNothing);

    // Back to All: the second row disappears (only the meta line remains).
    await tester.tap(find.text('All'));
    await settle(tester);
    expect(find.text('Story Gamma'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('sources screen: rename folder, move source, delete folder',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const SourcesScreen(),
    ));
    await settle(tester);
    expect(find.text('News'), findsOneWidget);
    expect(find.textContaining('2 sources'), findsOneWidget);

    // Rename via the folder's edit icon.
    await tester.tap(find.byTooltip('Rename folder'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Press');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('Press'), findsOneWidget);
    expect(find.text('News'), findsNothing);

    // Move the top-level source into the folder via its options menu, which
    // lists the destinations directly.
    await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Gamma'),
        matching: find.byTooltip('Source options')));
    await settle(tester);
    await tester.tap(find.text('Move to "Press"'));
    await settle(tester);
    expect(find.textContaining('3 sources'), findsOneWidget);

    // Delete the folder, moving its sources to the top level (default).
    await tester.tap(find.byTooltip('Remove folder'));
    await settle(tester);
    await tester.tap(find.text('Move to top level'));
    await settle(tester);
    expect(find.text('Press'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);

    // Restore the folder layout for any later tests.
    final restored = await tester.runAsync(() async {
      final folder = await db.insertFolder('News');
      await db.setSourceFolder(alpha.id!, folder.id);
      await db.setSourceFolder(beta.id!, folder.id);
      return folder;
    });
    expect(restored, isNotNull);
  });
}
