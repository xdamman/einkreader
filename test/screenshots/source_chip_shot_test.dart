// Source chips in the feed act on the source in place: long-press picks a
// chip up to drop it on a folder (which lights up under it), double-tap
// renames. Run:
//
//   flutter test test/screenshots/source_chip_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_chip_shot').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_chip_arch').path);
    await _loadFonts();
    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600 * 1000;
    final news = await db.insertFolder('News');
    final tech = await db.insertFolder('Tech');
    var n = 0;
    Future<void> add(String title, List<String> stories,
        {int? folderId}) async {
      final source = await db.insertSource(Source(
          type: SourceType.rss,
          title: title,
          url: 'https://${title.hashCode}.example/feed',
          createdAt: 0));
      if (folderId != null) await db.setSourceFolder(source.id!, folderId);
      for (final story in stories) {
        n++;
        await db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: story,
          title: story,
          contentMarkdown: 'Body',
          publishedAt: now - n * 3 * hour,
          createdAt: now - n * 3 * hour,
          fetched: 1,
        ));
      }
    }

    await add('The Guardian', ['Ministers agree a new climate package'],
        folderId: news.id);
    await add('Stratechery', [
      'The Apple Vision Pro, One Year Later',
      'Netflix and the Ads Tier Inflection',
    ]);
    await add('Hacker News', ['Show HN: a reader for e-ink tablets'],
        folderId: tech.id);
    await add('Daring Fireball', ['On the new iPad keyboard']);
    await add('Ars Technica', ['A closer look at e-ink refresh rates']);
    await add('Le Monde', ['La rentrée littéraire en dix livres'],
        folderId: news.id);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
  }

  void eink(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 800) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEinkTheme(),
      home: const HomeScreen());

  testWidgets('drag a source chip onto a folder', (tester) async {
    eink(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    final from = tester.getCenter(find.text('Ars Technica').first);
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    final to = tester.getCenter(find.text('Tech').first);
    for (var i = 1; i <= 6; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 6)!);
      await tester.pump();
    }
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/source_chip_1_drag.png'));
    await gesture.up();
    await settle(tester);
    await tester.tap(find.text('Tech'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/source_chip_2_moved.png'));
    await tester.pump(const Duration(minutes: 2));
  }, skip: !_enabled);

  testWidgets('double-tap a source chip', (tester) async {
    eink(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    final chip = find.text('Daring Fireball').first;
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(chip);
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Daring Fireball (Gruber)');
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/source_chip_3_rename.png'));
    await tester.pump(const Duration(minutes: 2));
  }, skip: !_enabled);
}

Future<void> _loadFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
  final cache =
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts');
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = await File(path).readAsBytes();
      loader.addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final f in ['Regular', 'Medium', 'Bold', 'Italic'])
      p.join(cache, 'Roboto-$f.ttf'),
  ]);
  await load('MaterialIcons', [p.join(cache, 'MaterialIcons-Regular.otf')]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
}
