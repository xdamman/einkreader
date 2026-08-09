// Renders the in-app profile view with shared highlights — kept in the
// harness so app/web parity stays checkable at a glance. Run with:
//
//   flutter test test/screenshots/profile_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/profile_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/profile_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    SyncService.instance.autoSyncOnLaunch = false;
    SharedPreferences.setMockInitialValues({
      'profile_secret_key': 'c' * 64,
      'profile_name': 'Xavier Damman',
      'profile_about': 'Reads on e-ink. Building open things.',
      'profile_links': 'https://xdamman.com',
      'profile_username': 'xavierdamman',
    });
    FlutterSecureStorage.setMockInitialValues({});
    ProfileService.instance.debugResetActiveCache();
    ArchiveStore.instance.debugConfigure(
        basePath:
            Directory.systemTemp.createTempSync('einkreader_pshot').path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    await db.debugReset();
    db.activeProfile = 'default';
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_pshot_db').path,
        'test.db');

    final source = await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Stratechery',
        url: 'https://stratechery.com/feed/',
        createdAt: 0));
    Future<int> article(String guid, String title, String url) async {
      await db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: guid,
          title: title,
          url: url,
          contentMarkdown: 'body',
          createdAt: 1,
          fetched: 1));
      return (await db.getArticles())
          .firstWhere((a) => a.guid == guid)
          .id!;
    }

    final a1 = await article('agg', 'Aggregation Theory, Redux',
        'https://stratechery.com/2026/aggregation');
    final a2 = await article('eink', 'Why e-ink is having a moment',
        'https://news.ycombinator.com/item?id=1');
    Future<void> share(int articleId, String text, String? comment) async {
      await db.insertHighlight(Highlight(
          articleId: articleId,
          text: text,
          comment: comment,
          shared: 1,
          createdAt: DateTime.now().millisecondsSinceEpoch));
      final h = (await db.getHighlights(articleId: articleId)).first;
      await db.insertShare(Share(
          highlightId: h.id!,
          medium: 'profile',
          createdAt: DateTime.now().millisecondsSinceEpoch));
    }

    await share(
        a1,
        'The internet enables zero marginal cost distribution, which '
            'pushes value to the ends of the network.',
        'The clearest framing of platform power I have read.');
    await share(a1, 'The scarce resource is no longer distribution but '
        'attention.', null);
    await share(a2, 'E-paper only draws power when it changes.',
        'Why a week of reading costs one charge.');
    await _loadFonts();
  });

  testWidgets('profile viewer tablet', (tester) async {
    tester.view.physicalSize = const Size(600, 800) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEinkTheme(),
      home: const ProfileScreen(),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/profile_tablet.png'));
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
  // The address strip uses the system monospace; alias it in the harness.
  await load('monospace', [p.join(cache, 'Roboto-Regular.ttf')]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
}
