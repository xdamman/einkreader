// What goes out on X when sharing a note on a post X won't let us quote:
// first the note with a link to the original post; when X refuses that too,
// the note with a screenshot of the post attached. The texts are the ones
// TwitterService.postTweet actually sends (against a fake API). Run:
//
//   flutter test test/screenshots/quote_fallback_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/services/tweet_card.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('screenshots');

const _quoted = QuotedTweet(
  id: '1845123456789012345',
  authorName: 'Patrick Collison',
  username: 'patrickc',
  text: "Brothers Karamazov was Einstein's favorite novel. Worth reading "
      'slowly, on paper or on e-ink.',
);

/// Posts [note] quoting [_quoted] against a fake X that refuses the quote,
/// and the link post too when [refuseLink]; returns what went out.
Future<Map<String, dynamic>> _post(String note,
    {required bool refuseLink}) async {
  Map<String, dynamic>? posted;
  final twitter = TwitterService(
    accessToken: () async => 'token',
    client: MockClient((request) async {
      if (request.url.path == '/2/media/upload') {
        return http.Response('{"data": {"id": "7"}}', 200);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body.containsKey('quote_tweet_id')) {
        return http.Response(
            '{"detail":"You can only reply to or quote posts where you '
            'are mentioned or are the author.","status":403}',
            403);
      }
      if (refuseLink && !body.containsKey('media')) {
        return http.Response('{"detail":"Not allowed."}', 403);
      }
      posted = body;
      return http.Response('{"data": {"id": "1"}}', 201);
    }),
  );
  await twitter.postTweet(note, quoted: _quoted);
  return posted!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const note = 'Adding this one to my reading list.';
  late Map<String, dynamic> linked;
  late Map<String, dynamic> withScreenshot;
  late Uint8List png;

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    linked = await _post(note, refuseLink: false);
    withScreenshot = await _post(note, refuseLink: true);
    png = await renderTweetCard(_quoted);
  });

  Future<void> shoot(WidgetTester tester, String title,
      Map<String, dynamic> posted, String golden) async {
    tester.view.physicalSize = const Size(600, 800) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final hasImage = posted.containsKey('media');

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildEinkTheme(),
      home: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(border: Border.all(width: 1.5)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(posted['text'] as String,
                    style: const TextStyle(fontSize: 17)),
                if (hasImage) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(png),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ));
    if (hasImage) {
      await tester.runAsync(() async {
        await precacheImage(MemoryImage(png),
            tester.element(find.byType(Scaffold)));
      });
    }
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/$golden'));
  }

  testWidgets('quote refused: note and link', (tester) async {
    expect(linked.containsKey('media'), isFalse);
    await shoot(tester, 'Quote refused: posted with a link', linked,
        'quote_fallback_link.png');
  }, skip: !_enabled);

  testWidgets('link refused too: note and screenshot', (tester) async {
    expect(withScreenshot['text'], note);
    await shoot(tester, 'Link refused too: posted with a screenshot',
        withScreenshot, 'quote_fallback_screenshot.png');
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
  await load('Atkinson Hyperlegible', [
    for (final f in ['Regular', 'Bold'])
      p.join('assets', 'fonts', 'AtkinsonHyperlegible-$f.ttf'),
  ]);
  await load('MaterialIcons', [p.join(cache, 'MaterialIcons-Regular.otf')]);
}
