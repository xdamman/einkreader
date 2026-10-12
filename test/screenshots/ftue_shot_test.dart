// The first-time experience: the empty feed, then the suggested-reads
// picker (for a French-speaking Belgian reader and an American one). Run:
//
//   flutter test test/screenshots/ftue_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/screens/suggested_sources_screen.dart';
import 'package:einkreader/services/archive_store.dart';
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
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ArchiveStore.instance.debugConfigure(
        basePath: Directory.systemTemp.createTempSync('einkreader_ftue').path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    await db.debugReset();
    db.activeProfile = 'default';
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_ftue_db').path,
        'test.db');
    await _loadFonts();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
  }

  void phone(WidgetTester tester, {double height = 915}) {
    tester.view.physicalSize = Size(412, height) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('empty feed on first launch', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildEinkTheme(),
        home: const HomeScreen()));
    for (var i = 0; i < 6; i++) {
      await settle(tester);
    }
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/ftue_1_empty.png'));
    await tester.tap(find.text('Or start with suggested reads'));
    await settle(tester);
    expect(find.text('Suggested reads'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
  }, skip: !_enabled);

  for (final (name, locale) in [
    ('fr_BE', const Locale('fr', 'BE')),
    ('en_US', const Locale('en', 'US')),
  ]) {
    testWidgets('suggested reads $name', (tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildEinkTheme(),
          home: SuggestedSourcesScreen(locale: locale)));
      await settle(tester);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/ftue_2_suggested_$name.png'));
    }, skip: !_enabled);
  }

  testWidgets('suggested reads, whole list', (tester) async {
    phone(tester, height: 4200);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildEinkTheme(),
        home: const SuggestedSourcesScreen(locale: Locale('fr', 'BE'))));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/ftue_3_suggested_all.png'));
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
