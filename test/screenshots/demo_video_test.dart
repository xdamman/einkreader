// Renders the demo-video frame sequence against the real app (seeded db,
// real fonts) — no emulator or screen recording needed. ffmpeg assembles
// the PNGs into the mp4 (see tool/make_demo_video.sh). Run with:
//
//   flutter test test/screenshots/demo_video_test.dart \
//     --update-goldens --dart-define=screenshots=true
//
// Frames land in test/screenshots/demo/ (gitignored; regenerate anytime).
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/share_note_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

// E-ink tablet portrait; physical = 1200x1600.
const _size = Size(600, 800);
const _dpr = 2.0;

late Article _story;
late Highlight _highlight;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    SyncService.instance.autoSyncOnLaunch = false;
    // A profile so the share dialog shows the profile channel checked.
    SharedPreferences.setMockInitialValues({
      'profile_secret_key': 'c' * 64,
      'profile_name': 'Xavier',
      'profile_username': 'xavierdamman',
    });
    FlutterSecureStorage.setMockInitialValues({});
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_demo').path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), 'einkreader.db'));
    await _seed();
    await _loadFonts();
  });

  group('demo frames', () {
    testWidgets('title cards', (tester) async {
      await _card(tester, '01_card_intro',
          title: 'einkreader.app',
          lines: ['The RSS reader', 'made for your e-ink device']);
      await _card(tester, '04_card_offline',
          title: 'Offline first',
          lines: ['Everything downloads on sync.', 'Read anywhere.']);
      await _card(tester, '08_card_highlights',
          title: 'Highlights',
          lines: ['Select any passage.', 'It stays yours, in Markdown.']);
      await _card(tester, '11_card_annotate',
          title: 'Annotate & share',
          lines: [
            'Add your thoughts.',
            'Share to your page — or keep it private.'
          ]);
      await _card(tester, '14_card_outro',
          title: 'einkreader.app',
          lines: ['The RSS reader', 'made for your e-ink device']);
    });

    testWidgets('feed and filter', (tester) async {
      await _shoot(tester, const HomeScreen(), '02_feed');
      await _shoot(tester, const HomeScreen(), '03_feed_filtered',
          setup: (t) async {
        await t.tap(find.text('Stratechery'));
      });
    });

    testWidgets('reader and scroll', (tester) async {
      // Distinct keys force a fresh reader State per frame (same widget
      // type would otherwise keep old scroll/highlights), and the saved
      // reading position is pinned so each drag is absolute from the top.
      Future<void> resetScroll() => tester.runAsync(
          () => AppDatabase.instance.saveScrollPosition(_story.id!, 0));
      await resetScroll();
      await _shoot(
          tester,
          ArticleScreen(key: const ValueKey('r0'), articleId: _story.id!),
          '05_reader');
      await resetScroll();
      await _shoot(
          tester,
          ArticleScreen(key: const ValueKey('r1'), articleId: _story.id!),
          '06_reader_scroll1', setup: (t) async {
        await t.drag(
            find.byType(SingleChildScrollView), const Offset(0, -520));
      });
      await resetScroll();
      await _shoot(
          tester,
          ArticleScreen(key: const ValueKey('r2'), articleId: _story.id!),
          '07_reader_scroll2', setup: (t) async {
        await t.drag(
            find.byType(SingleChildScrollView), const Offset(0, -1040));
      });
    });

    testWidgets('highlighting grows word by word, then its menu',
        (tester) async {
      const sentence =
          'The internet enables zero marginal cost distribution, '
          'which pushes value to the ends of the network.';
      final words = sentence.split(' ');
      // Five growing selections read as the act of highlighting.
      final steps = [4, 8, 12, 16, words.length];
      for (var i = 0; i < steps.length; i++) {
        final partial = words.take(steps[i]).join(' ');
        await tester.runAsync(() async {
          final db = AppDatabase.instance;
          // The reader restores the saved position — pin it to the top so
          // the highlighted sentence is in view.
          await db.saveScrollPosition(_story.id!, 0);
          for (final h in await db.getHighlights(articleId: _story.id!)) {
            await db.deleteHighlight(h.id!);
          }
          await db.insertHighlight(Highlight(
              articleId: _story.id!,
              text: partial,
              createdAt: DateTime.now().millisecondsSinceEpoch));
        });
        await _shoot(
            tester,
            ArticleScreen(
                key: ValueKey('hl$i'), articleId: _story.id!),
            '09_hl_${i + 1}');
      }
      _highlight = (await tester.runAsync(() =>
          AppDatabase.instance.getHighlights(articleId: _story.id!)))!
          .first;

      // Tapping the painted highlight opens the anchored menu:
      // Add note / Share… / Remove highlight.
      await tester.runAsync(
          () => AppDatabase.instance.saveScrollPosition(_story.id!, 0));
      await _shoot(
          tester,
          ArticleScreen(
              key: const ValueKey('menu'), articleId: _story.id!),
          '10_hl_menu', setup: (t) async {
        TapGestureRecognizer? tap;
        void walk(InlineSpan span) {
          if (span is TextSpan) {
            if (span.style?.backgroundColor != null &&
                span.recognizer is TapGestureRecognizer) {
              tap = span.recognizer as TapGestureRecognizer;
            }
            (span.children ?? const <InlineSpan>[]).forEach(walk);
          }
        }

        for (final rich in t.widgetList<RichText>(find.byType(RichText))) {
          walk(rich.text);
        }
        tap!.onTapUp!(TapUpDetails(
            kind: PointerDeviceKind.touch,
            globalPosition: const Offset(320, 420)));
      });
    });

    testWidgets('annotate and share dialog', (tester) async {
      await _shoot(
        tester,
        Stack(children: [
          ArticleScreen(articleId: _story.id!),
          // The barrier scrim a real showDialog draws: the reader stays
          // visible but dimmed behind the overlay.
          Positioned.fill(child: ColoredBox(color: Colors.black54)),
          ShareNoteDialog(
              article: _story, highlight: _highlight, shareByDefault: true),
        ]),
        '12_share_dialog',
        setup: (t) async {
          await t.enterText(
              find.widgetWithText(TextField, 'Your note (optional)'),
              'The clearest framing of platform power I have read.');
        },
      );
    });

    testWidgets('resume reading back home', (tester) async {
      await tester.runAsync(() =>
          AppDatabase.instance.saveScrollPosition(_story.id!, 900));
      await _shoot(tester, const HomeScreen(), '13_resume');
    });
  }, skip: _enabled ? false : 'Run with --dart-define=screenshots=true');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)));
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 3));
  } on FlutterError {
    // Perpetual animations never settle; capture as-is.
  }
}

Future<void> _shoot(WidgetTester tester, Widget screen, String name,
    {Future<void> Function(WidgetTester)? setup}) async {
  tester.view.physicalSize = _size * _dpr;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildEinkTheme(),
    home: screen,
  ));
  await _settle(tester);
  if (setup != null) {
    await setup(tester);
    await _settle(tester);
  }
  await expectLater(
      find.byType(MaterialApp), matchesGoldenFile('demo/$name.png'));
  await tester.pump(const Duration(minutes: 2));
}

/// Full-frame talking-point card in the app's e-ink look.
Future<void> _card(WidgetTester tester, String name,
    {required String title, required List<String> lines}) async {
  await _shoot(
    tester,
    Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 4,
              color: Colors.black,
              margin: const EdgeInsets.only(bottom: 28),
            ),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: readingFontFamily,
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                    height: 1.2)),
            const SizedBox(height: 18),
            for (final line in lines)
              Text(line,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: readingFontFamily,
                      fontSize: 21,
                      height: 1.5)),
            Container(
              width: 64,
              height: 4,
              color: Colors.black,
              margin: const EdgeInsets.only(top: 28),
            ),
          ],
        ),
      ),
    ),
    name,
  );
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
    for (final f in ['Regular', 'Medium', 'Bold', 'Italic', 'Light'])
      p.join(cache, 'Roboto-$f.ttf'),
  ]);
  await load('MaterialIcons', [p.join(cache, 'MaterialIcons-Regular.otf')]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
}

const _storyMarkdown = '''
The best way to understand the internet's effect on business is to start
with distribution. For most of the twentieth century, distribution was
scarce: shelf space, broadcast slots, delivery trucks. Whoever controlled
distribution controlled the market.

The internet enables zero marginal cost distribution, which pushes value
to the ends of the network. Suddenly anyone can reach anyone; the scarce
resource is no longer distribution but attention.

## Aggregators

This is where aggregators come in. By owning the user relationship and
commoditizing supply, aggregators invert the old power structure. Users
come to them directly, suppliers follow the users, and the aggregator's
leverage compounds with every new reader.

Consider what this means for publishing in particular. The unit of
consumption shifted from the publication to the article; the front page
gave way to the feed. Discovery, once the job of an editor, became the
job of an algorithm — one tuned for engagement rather than understanding.

## The reader's countermove

And yet the same economics cut the other way. If distribution is free,
then a reader can assemble their own front page: a feed of writers worth
trusting, fetched directly, owned locally, read without surveillance.

That is the quiet promise of open protocols — RSS then, Nostr now. The
tools of aggregation can serve the reader instead of the platform: your
sources, your archive, your highlights, on your own device, in files you
can open in twenty years.

The bottleneck moved from intelligence to coordination; the reader's
bottleneck moved from access to attention. Guard it accordingly.
''';

Future<void> _seed() async {
  final db = AppDatabase.instance;
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 3600 * 1000;
  const day = 24 * hour;

  Future<Source> source(SourceType type, String title, String url) =>
      db.insertSource(
          Source(type: type, title: title, url: url, createdAt: now));

  final stratechery = await source(
      SourceType.rss, 'Stratechery', 'https://stratechery.com/feed/');
  final acx = await source(SourceType.rss, 'Astral Codex Ten',
      'https://astralcodexten.substack.com/feed');
  final hn = await source(
      SourceType.rss, 'Hacker News: Best', 'https://hnrss.org/best');
  final tw = await source(
      SourceType.twitterBookmarks, 'Twitter Bookmarks', 'xdamman');

  Future<Article> article(Source s, String guid, String title,
      String author, int published, String content,
      {bool read = false, bool readLater = false}) async {
    await db.insertArticleIfNew(Article(
      sourceId: s.id!,
      guid: guid,
      title: title,
      author: author,
      url: 'https://example.com/$guid',
      publishedAt: published,
      contentMarkdown: content,
      fetched: 1,
      read: read ? 1 : 0,
      readLater: readLater ? 1 : 0,
      createdAt: published,
    ));
    return (await db.getArticles())
        .firstWhere((a) => a.guid == guid);
  }

  _story = await article(
      stratechery,
      'aggregation-redux',
      'Aggregation Theory, Redux',
      'Ben Thompson',
      now - 2 * hour,
      _storyMarkdown);
  await article(
      hn,
      'eink-moment',
      'Why e-ink displays are having a moment',
      'jandeboevrie',
      now - 5 * hour,
      '## Reflective screens\n\nE-paper only draws power when it changes.',
      readLater: true);
  await article(
      acx,
      'roots-progress',
      'Book Review: The Roots of Progress',
      'Scott Alexander',
      now - day - 4 * hour,
      '# Progress studies\n\nWhy did growth take off in 1750?',
      readLater: true);
  await article(
      tw,
      'paper-screens',
      'The case for reading on paper-like screens',
      'Readwise',
      now - day - 8 * hour,
      'Long-form reading on emissive screens competes with every '
      'notification you have ever allowed.');
  await article(
      acx,
      'links-august',
      'Links For August',
      'Scott Alexander',
      now - 2 * day,
      'A monthly collection of interesting links.',
      read: true);
}
