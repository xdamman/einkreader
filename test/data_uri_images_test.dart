// Some blogs (vitalik.eth.limo, for one) embed every picture in the page as a
// base64 `data:` URI instead of linking a file. Those images used to show up
// blank: the reader handed them to the network loader, and sync never stored
// them. Now sync saves them on the device like any other picture, and the
// reader can show one still embedded in the text.
import 'dart:io';

import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/extractor.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A 1×1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const _dataUri = 'data:image/png;base64,$_png';
const _dataUri2 = 'data:image/webp;base64,UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('the extractor keeps embedded images', () {
    final para = 'A paragraph long enough to count as article text here. ' * 3;
    final html = '<article><p>$para</p>'
        '<img src="$_dataUri" width="250">'
        '<p>$para</p></article>';
    final md = ArticleExtractor.extract(html,
        baseUrl: 'https://vitalik.eth.limo/general/post.html')!;
    expect(md, contains('![]($_dataUri)'));
  });

  group('sync stores embedded images on the device', () {
    late Directory tmp;
    var requests = 0;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('data_uri_test');
      requests = 0;
      ArchiveStore.instance.debugConfigure(
        basePath: tmp.path,
        client: MockClient((_) async {
          requests++;
          return http.Response('', 404);
        }),
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('as files, without any download', () async {
      const md = 'Intro.\n\n![]($_dataUri)\n\nOutro.';
      expect(ArchiveStore.hasRemoteImages(md), isTrue);

      final out = await ArchiveStore.instance.localizeMarkdown(md,
          relDir: '2026/vitalik', maxDimension: 1200);

      expect(requests, 0);
      expect(out, isNot(contains('data:')));
      expect(ArchiveStore.hasRemoteImages(out), isFalse);
      final ref = RegExp(r'\]\((eink-img://[^)]+)\)').firstMatch(out)!.group(1)!;
      // The reference carries no copy of the (often huge) embedded data.
      expect(ref, isNot(contains('#')));
      expect(ref, endsWith('.png'));
      final file = File(p.join(tmp.path, ref.substring('eink-img://'.length)));
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
    });

    test('a broken embedded image is left as it was', () async {
      const md = '![](data:image/png;base64,%%%not-base64)';
      final out = await ArchiveStore.instance.localizeMarkdown(md,
          relDir: '2026/vitalik', maxDimension: 1200);
      expect(out, md);
    });
  });

  testWidgets('the reader shows embedded images, side by side ones too',
      (tester) async {
    const markdown = 'Intro paragraph.\n\n'
        '![]($_dataUri)\n\n'
        '![]($_dataUri)![]($_dataUri2)\n\n'
        '*Left: one app. Right: another.*';

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: MarkdownView(markdown: markdown)),
      ),
    ));

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(3));
    expect(images.every((i) => i.image is MemoryImage), isTrue);
    final texts = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((rt) => rt.text.toPlainText())
        .join('\n');
    expect(texts, isNot(contains('data:')));
    expect(texts, isNot(contains('![')));
  });
}
