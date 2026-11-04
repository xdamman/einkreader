// A blog post whose pictures are embedded in the page (base64 `data:` URIs,
// as on vitalik.eth.limo): synced like any article, its pictures now show,
// two side-by-side ones one under the other. Run:
//
//   flutter test test/screenshots/data_uri_images_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
//
// Add --dart-define=page=<saved .html> to render a real page instead, and
// --dart-define=picture=<n> to center its n-th picture in the first shot.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/extractor.dart';
import 'package:einkreader/services/reading_settings.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');
const _page = String.fromEnvironment('page');
/// Which picture the first shot centers (0 = the first).
const _picture0 = int.fromEnvironment('picture');

/// A drawn picture, embedded as a PNG data URI.
String _picture(int w, int h, int seed) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(245, 245, 245));
  for (var x = 0; x < w; x += 24) {
    img.drawLine(image,
        x1: x, y1: 0, x2: x, y2: h, color: img.ColorRgb8(210, 210, 210));
  }
  for (var y = 0; y < h; y += 24) {
    img.drawLine(image,
        x1: 0, y1: y, x2: w, y2: y, color: img.ColorRgb8(210, 210, 210));
  }
  for (var i = 0; i < 9; i++) {
    final cx = (seed * 37 + i * 71) % w, cy = (seed * 53 + i * 47) % h;
    img.fillCircle(image,
        x: cx, y: cy, radius: 10 + (i * 7) % 22, color: img.ColorRgb8(60, 60, 60));
  }
  img.drawRect(image,
      x1: 0, y1: 0, x2: w - 1, y2: h - 1, color: img.ColorRgb8(0, 0, 0));
  return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
}

String _syntheticPage() {
  const para = 'Over the past year I have been trying to use my devices less, '
      'and to make the time I do spend on them count. Part of that is '
      'swapping apps that pull at my attention for small tools that do one '
      'thing and get out of the way.';
  return '<html><body><article>'
      '<p>$para</p>'
      '<p><img src="${_picture(600, 360, 1)}"></p>'
      '<p><em>A map of quiet places to read.</em></p>'
      '<p>$para</p>'
      '<p><img src="${_picture(250, 420, 2)}" width="250">'
      '<img src="${_picture(250, 420, 3)}" width="250"></p>'
      '<p><em>Left: one notes app. Right: another.</em></p>'
      '<p>$para</p>'
      '</article></body></html>';
}

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
        Directory.systemTemp.createTempSync('einkreader_datauri_shot').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath: Directory.systemTemp
            .createTempSync('einkreader_datauri_arch')
            .path);
    await _loadFonts();
    final html =
        _page.isEmpty ? _syntheticPage() : File(_page).readAsStringSync();
    final markdown = ArticleExtractor.extract(html,
        baseUrl: 'https://vitalik.eth.limo/general/post.html')!;
    // What sync does: the embedded pictures are stored on the device.
    final stored = await ArchiveStore.instance.localizeMarkdown(markdown,
        relDir: '2026/vitalik', maxDimension: 1500);
    final source = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Vitalik Buterin',
        url: 'https://vitalik.eth.limo',
        createdAt: 0));
    await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'minimalism',
        title: 'Digital minimalism',
        contentMarkdown: stored,
        publishedAt: DateTime(2026, 10, 31).millisecondsSinceEpoch,
        createdAt: DateTime(2026, 10, 31).millisecondsSinceEpoch,
        fetched: 1,
        read: 1));
    id = (await db.getArticles()).single.id!;
    expect(stored, contains(ArchiveStore.scheme));
    expect(stored, isNot(contains('data:')));
    await ReadingSettings.instance
        .update(const ReadingPrefs(paginated: false, fontSize: 20));
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> shoot(WidgetTester tester, String golden,
      {Finder? scrollTo, double alignment = 1.0}) async {
    tester.view.physicalSize = const Size(750, 1000) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildEinkTheme(),
        home: ArticleScreen(articleId: id)));
    await settle(tester);
    if (scrollTo != null) {
      await tester.scrollUntilVisible(scrollTo, 300,
          scrollable: find.byType(Scrollable).first);
      // The caption at the bottom: the pictures above it in view.
      await tester.runAsync(() => Scrollable.ensureVisible(
          scrollTo.evaluate().first,
          alignment: alignment));
      await settle(tester);
    }
    // Decode the stored pictures for real (the test clock doesn't load
    // files on its own).
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element)
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await settle(tester);
    // Decoded pictures have grown to their size: center again.
    if (scrollTo != null) {
      await tester.runAsync(() => Scrollable.ensureVisible(
          scrollTo.evaluate().first,
          alignment: alignment));
      await settle(tester);
    }
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/$golden.png'));
  }

  testWidgets('embedded pictures', (tester) async {
    // A picture, mid-screen.
    await shoot(tester, 'data_uri_images_1',
        scrollTo: find.byType(Image).at(_picture0), alignment: 0.5);
  }, skip: !_enabled);

  testWidgets('side by side pictures', (tester) async {
    await shoot(tester, 'data_uri_images_2',
        scrollTo: find.textContaining('Right:', findRichText: true));
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
