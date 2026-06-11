// Renders the real app screens against a seeded database and captures
// PNGs, no emulator required. Run with:
//
//   flutter test test/screenshots/screenshot_test.dart \
//     --update-goldens --dart-define=screenshots=true
//
// Images are written to test/screenshots/goldens/.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/add_source_screen.dart';
import 'package:einkreader/screens/article_list_screen.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/screens/highlights_screen.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/screens/settings_screen.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

late int _featuredArticleId;
Source? _featuredSource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    SyncService.instance.autoSyncOnLaunch = false;
    SharedPreferences.setMockInitialValues({
      'nostr_npub':
          'npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m',
    });
    FlutterSecureStorage.setMockInitialValues({});

    sqfliteFfiInit();
    // No background isolate: queries complete inside the widget-test zone.
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), 'einkreader.db'));
    await _seed();
    await _loadFonts();
  });

  group('screenshots', () {
    testWidgets('home tablet', (tester) async {
      await _capture(tester, const HomeScreen(), 'home_tablet', _tablet);
    });

    testWidgets('article list tablet', (tester) async {
      await _capture(tester, ArticleListScreen(source: _featuredSource),
          'article_list_tablet', _tablet);
    });

    testWidgets('reader with highlights tablet', (tester) async {
      await _capture(tester, ArticleScreen(articleId: _featuredArticleId),
          'reader_tablet', _tablet);
    });

    testWidgets('highlights tablet', (tester) async {
      await _capture(
          tester, const HighlightsScreen(), 'highlights_tablet', _tablet);
    });

    testWidgets('settings tablet', (tester) async {
      await _capture(
          tester, const SettingsScreen(), 'settings_tablet', _tablet);
    });

    testWidgets('add source tablet', (tester) async {
      await _capture(
          tester, const AddSourceScreen(), 'add_source_tablet', _tablet);
    });

    testWidgets('home phone', (tester) async {
      await _capture(tester, const HomeScreen(), 'home_phone', _phone);
    });

    testWidgets('reader phone', (tester) async {
      await _capture(tester, ArticleScreen(articleId: _featuredArticleId),
          'reader_phone', _phone);
    });
  }, skip: _enabled ? false : 'Run with --dart-define=screenshots=true');
}

// E-ink tablet (3:4) and phone shapes; physical = logical * dpr.
const _tablet = (Size(600, 800), 2.0);
const _phone = (Size(390, 844), 3.0);

Future<void> _capture(WidgetTester tester, Widget screen, String name,
    (Size, double) shape) async {
  tester.view.physicalSize = shape.$1 * shape.$2;
  tester.view.devicePixelRatio = shape.$2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEinkTheme(),
    home: screen,
  ));
  // Let real async work (sqflite ffi isolate, prefs) complete.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)));
  await tester.pumpAndSettle();
  await expectLater(
      find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

Future<void> _loadFonts() async {
  // Real fonts instead of the blocky test font: Roboto + icons from the
  // Flutter SDK cache, PT Serif standing in for the reading serif.
  final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
  final cache =
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts');

  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      if (!File(path).existsSync()) {
        throw StateError('Font not found: $path');
      }
      final bytes = await File(path).readAsBytes();
      loader.addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final f in ['Regular', 'Medium', 'Bold', 'Italic', 'Light'])
      p.join(cache, 'Roboto-$f.ttf'),
  ]);
  await load('MaterialIcons', [p.join(cache, 'MaterialIcons-Regular.otf')]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
}

Future<void> _seed() async {
  final db = AppDatabase.instance;
  final day = DateTime(2026, 6, 10, 9).millisecondsSinceEpoch;
  const hour = 3600 * 1000;

  Future<Source> source(SourceType type, String title, String url) =>
      db.insertSource(
          Source(type: type, title: title, url: url, createdAt: day));

  final stratechery = await source(
      SourceType.rss, 'Stratechery', 'https://stratechery.com/feed/');
  final acx = await source(SourceType.rss, 'Astral Codex Ten',
      'https://astralcodexten.substack.com/feed');
  final hn = await source(
      SourceType.rss, 'Hacker News: Best', 'https://hnrss.org/best');
  final twBookmarks = await source(
      SourceType.twitterBookmarks, 'Twitter Bookmarks', 'xdamman');
  await source(SourceType.twitterLikes, 'Twitter Likes', 'xdamman');
  await source(SourceType.nostrBookmarks, 'Nostr Bookmarks', 'npub1sg6…');

  _featuredSource = stratechery;

  Future<void> article(Source s, String guid, String title, String author,
      int published, String? content,
      {bool read = false, String? url}) async {
    await db.insertArticleIfNew(Article(
      sourceId: s.id!,
      guid: guid,
      title: title,
      author: author,
      url: url ?? 'https://example.com/$guid',
      publishedAt: published,
      summary: null,
      contentMarkdown: content,
      fetched: content == null ? 0 : 1,
      read: read ? 1 : 0,
      createdAt: published,
    ));
  }

  await article(stratechery, 'aggregation-redux', 'Aggregation Theory, Redux',
      'Ben Thompson', day - 2 * hour, _featuredMarkdown);
  await article(
      stratechery,
      'ai-distribution',
      'AI and the Future of Distribution',
      'Ben Thompson',
      day - 30 * hour,
      '## A new gatekeeper\n\nDistribution used to be scarce.',
      read: true);
  await article(
      acx,
      'book-review-progress',
      'Book Review: The Roots of Progress',
      'Scott Alexander',
      day - 8 * hour,
      '# Progress studies\n\nWhy did growth take off in 1750?');
  await article(acx, 'links-june', 'Links For June', 'Scott Alexander',
      day - 50 * hour, '1. First link\n2. Second link',
      read: true);
  await article(
      hn,
      'eink-displays',
      'Why e-ink displays are having a moment',
      'jandeboevrie',
      day - 5 * hour,
      '## Reflective screens\n\nE-paper only draws power when it changes.');
  await article(hn, 'sqlite-vfs', 'SQLite as a file system', 'pwg',
      day - 26 * hour, null);
  await article(
      twBookmarks,
      '1932810021',
      'The case for reading on paper-like screens',
      'Readwise',
      day - 12 * hour,
      '> Bookmarked tweet\n\n---\n\nLong-form reading on emissive screens '
          'competes with every notification you have ever allowed.');

  final articles = await db.getArticles(sourceId: stratechery.id);
  _featuredArticleId =
      articles.firstWhere((a) => a.guid == 'aggregation-redux').id!;

  for (final text in [
    'the internet made distribution free, and in doing so moved the point '
        'of leverage from controlling scarce supply to owning consumer '
        'demand',
    'Value flows to whoever owns the scarcest resource in the chain.',
  ]) {
    await db.insertHighlight(Highlight(
        articleId: _featuredArticleId,
        text: text,
        createdAt: day - hour));
  }
}

const _featuredMarkdown = '''
The most important thing to understand about the internet is that it
inverted the economics of media and commerce. Before, distribution was the
bottleneck; whoever owned the printing press, the broadcast license or the
shelf space captured the margin.

## The inversion

Then the internet made distribution free, and in doing so moved the point
of leverage from controlling scarce supply to owning consumer demand.
Aggregators win not by owning content but by owning the **relationship
with users**, which suppliers must then compete for.

> The value chain is conserved: when one piece is commoditized, value
> flows to an adjacent piece.

This has three consequences:

- Suppliers are commoditized and must differentiate on the aggregator's
  terms.
- User experience becomes the primary competitive vector.
- Network effects compound: more users attract more supply, which
  attracts more users.

Value flows to whoever owns the scarcest resource in the chain. On the
modern internet that resource is *attention*, and the [companies that
aggregate it](https://example.com/aggregators) are the most valuable in
the world.

## What comes next

The open question is whether AI assistants become the next aggregation
layer — sitting between users and every existing aggregator, the way
aggregators sat between users and every existing publisher.
''';
