import 'dart:io';

import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('path helpers', () {
    test('slug is kebab-cased, capped and never empty', () {
      expect(ArchiveStore.slug('The Rebel Alliance!'), 'the-rebel-alliance');
      expect(ArchiveStore.slug('  ***  '), 'untitled');
      expect(ArchiveStore.slug('a' * 100).length, lessThanOrEqualTo(60));
    });

    test('day / source paths (year first, no month folder)', () {
      final date = DateTime(2026, 6, 12);
      expect(ArchiveStore.dayStamp(date), '20260612');
      expect(ArchiveStore.sourceDir(date, 'Stratechery'), '2026/stratechery');
    });
  });

  group('filesystem', () {
    late Directory tmp;
    final source = const Source(
        type: SourceType.rss, title: 'Stratechery', url: 'x', createdAt: 0);
    final article = Article(
      sourceId: 1,
      guid: 'g1',
      title: 'Aggregation Theory',
      author: 'Ben',
      url: 'https://stratechery.com/p',
      publishedAt: DateTime(2026, 6, 12).millisecondsSinceEpoch,
      createdAt: DateTime(2026, 6, 12).millisecondsSinceEpoch,
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('archive_test');
      final client = MockClient((req) async => http.Response.bytes(
            [137, 80, 78, 71], // tiny PNG-ish blob, under the resize threshold
            200,
            headers: {'content-type': 'image/png'},
          ));
      ArchiveStore.instance.debugConfigure(basePath: tmp.path, client: client);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('localizeMarkdown downloads images and rewrites refs', () async {
      final md = await ArchiveStore.instance.localizeMarkdown(
        'before ![pic](https://cdn.example.com/a.png) after',
        relDir: '2026/06/stratechery',
        maxDimension: 1000,
      );
      final ref = RegExp(r'eink-img://[^)\s]+').firstMatch(md)!.group(0)!;
      expect(ref, startsWith('eink-img://2026/06/stratechery/images/'));
      expect(ref, endsWith('.png'));
      // Resolves to a real file on disk.
      final file = ArchiveStore.localFile(ref)!;
      expect(file.existsSync(), isTrue);
      expect(p.isWithin(tmp.path, file.path), isTrue);
    });

    test('writeArticle writes a dated .md with portable image refs', () async {
      final localized = await ArchiveStore.instance.localizeMarkdown(
        '# Body\n\n![](https://cdn.example.com/a.png)',
        relDir: '2026/06/stratechery',
        maxDimension: 1000,
      );
      await ArchiveStore.instance.writeArticle(
          source: source,
          article: article.copyWith(contentMarkdown: localized),
          markdown: localized);

      final file = File(p.join(tmp.path, '2026', 'stratechery',
          '20260612-aggregation-theory.md'));
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('title: "Aggregation Theory"'));
      expect(text, contains('source: "Stratechery"'));
      // Portable relative ref, not the app-internal scheme.
      expect(text, contains('](images/'));
      expect(text, isNot(contains('eink-img://')));
    });

    test('copyToFavorites copies the markdown and its images', () async {
      final localized = await ArchiveStore.instance.localizeMarkdown(
        '![](https://cdn.example.com/a.png)',
        relDir: '2026/06/stratechery',
        maxDimension: 1000,
      );
      await ArchiveStore.instance.copyToFavorites(
          source: source,
          article: article.copyWith(contentMarkdown: localized),
          markdown: localized);

      final favMd = File(p.join(tmp.path, '2026', 'favorites',
          '20260612-aggregation-theory.md'));
      expect(favMd.existsSync(), isTrue);
      final favImages = Directory(p.join(tmp.path, '2026', 'favorites',
          'images'));
      expect(favImages.listSync().whereType<File>(), isNotEmpty);
    });

    test('moveTo relocates the archive and keeps image refs resolving',
        () async {
      final md = await ArchiveStore.instance.localizeMarkdown(
        '![pic](https://cdn.example.com/a.png)',
        relDir: '2026/06/stratechery',
        maxDimension: 1000,
      );
      final ref = RegExp(r'eink-img://[^)\s]+').firstMatch(md)!.group(0)!;

      final dest = Directory.systemTemp.createTempSync('archive_move');
      addTearDown(() {
        if (dest.existsSync()) dest.deleteSync(recursive: true);
      });
      await ArchiveStore.instance.moveTo(dest.path);

      // The same eink-img:// ref now resolves inside the new base, the file
      // moved with it, and the old tree is gone.
      final file = ArchiveStore.localFile(ref)!;
      expect(p.isWithin(dest.path, file.path), isTrue);
      expect(file.existsSync(), isTrue);
      expect(tmp.existsSync(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ArchiveStore.dirPrefKey), dest.path);
      await prefs.remove(ArchiveStore.dirPrefKey);

      // Recreate tmp so tearDown's recursive delete doesn't fail.
      tmp.createSync(recursive: true);
    });

    test('moveTo rejects a folder inside the current archive', () async {
      expect(
        () => ArchiveStore.instance.moveTo(p.join(tmp.path, 'sub')),
        throwsA(isA<Exception>()),
      );
    });

    test('writeHighlights groups by article into one file', () async {
      await ArchiveStore.instance.writeHighlights([
        const Highlight(
            articleId: 1,
            text: 'first line\nsecond line',
            createdAt: 0,
            articleTitle: 'My Post'),
        const Highlight(
            articleId: 2, text: 'another', createdAt: 0, articleTitle: 'Other'),
      ]);
      final file = File(p.join(tmp.path, 'highlights.md'));
      expect(file.existsSync(), isTrue);
      final text = file.readAsStringSync();
      expect(text, contains('# Highlights'));
      expect(text, contains('## My Post'));
      expect(text, contains('> first line'));
      expect(text, contains('## Other'));
    });
  });
}
