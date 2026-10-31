// The note overlay reopened after being closed by mistake: the unsaved
// note is back, flagged as a draft, with a way to discard it. Run:
//
//   flutter test test/screenshots/note_draft_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/share_note_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Article article;
  late Highlight highlight;

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_draft_shot').path,
        'test.db');
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_draft_arch').path);
    await _loadFonts();
    final source = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Stratechery',
        url: 'https://stratechery.com/feed/',
        createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'agg',
      title: 'Aggregation Theory, Redux',
      author: 'Ben Thompson',
      url: 'https://stratechery.com/agg',
      contentMarkdown: _body,
      publishedAt: 0,
      createdAt: 0,
      fetched: 1,
    ));
    article = (await db.getArticles()).single;
    await db.insertHighlight(Highlight(
        articleId: article.id!, text: _quote, createdAt: 1));
    highlight = (await db.getHighlights()).single;
    // What was typed before the overlay got closed by mistake.
    await NoteDrafts.save(NoteDrafts.keyFor(article, [highlight]),
        'This is why owning the reader matters more than owning the '
        'printing press. Worth rereading next to');
  });

  testWidgets('note draft restored', (tester) async {
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
        home: Stack(children: [
          ArticleScreen(articleId: article.id!),
          const Positioned.fill(child: ColoredBox(color: Colors.black54)),
          ShareNoteDialog(
              article: article,
              highlights: [highlight],
              shareByDefault: false),
        ])));
    await settle();
    await settle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/note_draft_restored.png'));
    await tester.pump(const Duration(minutes: 2));
  }, skip: !_enabled);
}

const _quote = 'Value flows to whoever owns the scarcest resource in the '
    'chain.';

const _body = 'The internet made distribution free, and in doing so moved '
    'the point of leverage from controlling scarce supply to owning '
    'consumer demand.\n\n$_quote For most of the last century that was '
    'distribution; today it is the relationship with the user.';

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
