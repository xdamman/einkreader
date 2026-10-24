// The end of an article: favorite and share, the next unread article of the
// feed with its summary, the others with their dates, then the feedback link on
// its own line. Run:
//
//   flutter test test/screenshots/more_from_feed_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int id;

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_more_shot').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_more_arch').path);
    await _loadFonts();
    final now = DateTime.now().millisecondsSinceEpoch;
    const hour = 3600 * 1000;
    final source = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Stratechery',
        url: 'https://stratechery.com/feed/',
        createdAt: 0));
    Future<void> add(String title, int at,
            {bool read = false, String? summary}) =>
        db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: title,
          title: title,
          author: 'Ben Thompson',
          url: 'https://stratechery.com/${title.hashCode}',
          summary: summary,
          contentMarkdown: _body,
          publishedAt: at,
          createdAt: at,
          fetched: 1,
          read: read ? 1 : 0,
        ));
    await add('Aggregation Theory, Redux', now - 40 * hour);
    await add('The Apple Vision Pro, One Year Later', now - 2 * hour,
        summary: 'A year in, the Vision Pro is a remarkable device in '
            'search of a reason to exist, and Apple seems to know it. What '
            'comes next says a lot about how the company sees the future.');
    await add('Netflix and the Ads Tier Inflection', now - 30 * hour,
        summary: 'The ads tier was supposed to be a sideshow. Instead it '
            'is now the engine of subscriber growth.');
    await add('AI and the Future of Distribution', now - 10 * hour,
        read: true);
    await add('Microsoft, OpenAI and the Platform Shift', now - 50 * hour,
        summary: 'Who owns the customer when the model is the product?');
    await add('The Super App Question, Revisited', now - 75 * hour,
        summary: 'Why the West never got its WeChat, and why that may '
            'finally be changing.');
    await add('Intel at the Crossroads', now - 100 * hour,
        summary: 'Foundry or product company: Intel cannot be both.');
    await add('Why Spotify Bought Podcasts', now - 150 * hour);
    final all = await db.getArticles();
    id = all.firstWhere((a) => a.title == 'Aggregation Theory, Redux').id!;
    // Seen in the feed but not read: listed, without the bold.
    await db.markArticlesSeen([
      all.firstWhere((a) => a.title.startsWith('Microsoft')).id!,
    ]);
  });

  testWidgets('article end', (tester) async {
    tester.view.physicalSize = const Size(600, 800) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildEinkTheme(),
        home: ArticleScreen(articleId: id)));
    await settle();
    // The article's last lines at the top, what follows below them.
    final lastLine = tester
        .getTopLeft(find.textContaining('relationship with the user',
            findRichText: true))
        .dy;
    await tester.drag(find.byType(SingleChildScrollView).first,
        Offset(0, -(lastLine - 40)));
    await settle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/more_from_feed.png'));
    await tester.pump(const Duration(minutes: 2));
  }, skip: !_enabled);
}

const _body = 'The internet made distribution free, and in doing so moved '
    'the point of leverage from controlling scarce supply to owning '
    'consumer demand.\n\n'
    'Value flows to whoever owns the scarcest resource in the chain. For '
    'most of the last century that was distribution; today it is the '
    'relationship with the user.';

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
