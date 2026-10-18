// Paged reading: every page ends after a whole line, at the end of a
// paragraph when it can. Run:
//
//   flutter test test/screenshots/paged_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/reading_settings.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

const _paragraphs = [
  'The village sits at the end of a valley road, two hours from the '
      'nearest city. Most houses are older than the people living in them, '
      'and a third stand empty. The school closed a decade ago.',
  'In 2021 the village did something no one expected: it sold digital '
      'art tied to the koi carp the area is known for. Holders became '
      '"digital villagers", soon outnumbered the people living there, and '
      'voted on how part of a budget was spent.',
  "It's still running. Digital villagers voted to expand the model to two "
      'more towns, and the project was still holding events last year.',
  'One is a network that went looking for a village. The other is a '
      'village that is looking for a network.',
  'There is always a hunger for better institutions. That points to a '
      'local fork of the movement: a network of domestic nodes, linked to '
      'each other and to nodes abroad. Same friends, same tools, same '
      'circuit, running through small towns. The question is whether the '
      'towns want it, and on whose terms the newcomers arrive, because a '
      'place that has lost its young people is careful about who it lets '
      'in and what they mean to change.',
  'For this to work in a culture this cautious, the idea has to meet the '
      'culture. It cannot arrive as exit or disruption. It has to be '
      'retrofitted into what already exists: community town-building, '
      'renovated empty houses, local festivals.',
  'Integration needs a host society willing to be changed by newcomers '
      'too. The realistic path is closer to assimilation: people who adopt '
      'the culture and, over years, earn the standing to change it.',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int id;

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_paged_shot').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_paged_arch').path);
    await _loadFonts();
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Blog', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'village',
        title: 'A village looking for a network',
        contentMarkdown: [for (var i = 0; i < 4; i++) ..._paragraphs].join('\n\n'),
        publishedAt: 1,
        createdAt: 1,
        fetched: 1,
        read: 1));
    id = (await db.getArticles()).single.id!;
    await ReadingSettings.instance
        .update(const ReadingPrefs(paginated: true, fontSize: 20));
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('paged pages', (tester) async {
    tester.view.physicalSize = const Size(750, 1000) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildEinkTheme(),
        home: ArticleScreen(articleId: id)));
    await settle(tester);
    for (var page = 1; page <= 3; page++) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/paged_$page.png'));
      await tester.tap(find.byTooltip('Next page'));
      await settle(tester);
    }
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
