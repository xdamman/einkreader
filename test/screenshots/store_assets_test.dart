// Renders Google Play store art (feature graphic 1024x500, hi-res icon
// 512x512) in the app's typographic style. Run with:
//
//   flutter test test/screenshots/store_assets_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _enabled = bool.fromEnvironment('screenshots');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_enabled) return;
    await _loadFonts();
  });

  group('store assets', () {
    testWidgets('feature graphic 1024x500', (tester) async {
      tester.view.physicalSize = const Size(1024, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 72, height: 5, color: Colors.black,
                    margin: const EdgeInsets.only(bottom: 22)),
                Text('einkreader',
                    style: TextStyle(
                        fontFamily: readingFontFamily,
                        fontSize: 78,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                        height: 1.1)),
                const SizedBox(height: 10),
                Text('An RSS reader made for your e-ink device',
                    style: TextStyle(
                        fontFamily: readingFontFamily,
                        fontSize: 26,
                        color: Colors.black)),
                const SizedBox(height: 8),
                const Text(
                    'Offline first · Highlights · Annotate · Share',
                    style: TextStyle(fontSize: 17, color: Colors.black54)),
                Container(
                    width: 72, height: 5, color: Colors.black,
                    margin: const EdgeInsets.only(top: 22)),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('store/feature_graphic.png'));
    });

    testWidgets('hi-res icon 512x512', (tester) async {
      tester.view.physicalSize = const Size(512, 512);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Text('e',
                style: TextStyle(
                    fontFamily: readingFontFamily,
                    fontSize: 340,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.0)),
          ),
        ),
      ));
      await tester.pump();
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('store/icon_512.png'));
    });
  }, skip: _enabled ? false : 'Run with --dart-define=screenshots=true');
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
    for (final f in ['Regular', 'Medium', 'Bold'])
      p.join(cache, 'Roboto-$f.ttf'),
  ]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
}
