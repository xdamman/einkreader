// Images are stored on the device only for articles being read: sync leaves
// them on the web, opening an article (or saving it to read) downloads them,
// and a daily cleanup gives the space back for articles nobody keeps.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _feed = '''<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel><title>Alpha</title>
<item><title>Pictures</title><link>https://alpha.example/p</link>
<guid>p1</guid><pubDate>Mon, 05 Oct 2026 10:00:00 GMT</pubDate>
<content:encoded><![CDATA[<p>Look at this, it is a long enough paragraph.</p>
<p><img src="https://cdn.example/a.png" alt="a"></p>]]></content:encoded>
</item></channel></rss>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final db = AppDatabase.instance;
  late Directory tempDir;
  late int imageRequests;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('eink_images_test');
    db.debugDatabasePath = p.join(tempDir.path, 'test.db');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    imageRequests = 0;
    ArchiveStore.instance.debugConfigure(
        basePath: tempDir.path,
        client: MockClient((_) async {
          imageRequests++;
          return http.Response.bytes(utf8.encode('img'), 200,
              headers: {'content-type': 'image/png'});
        }));
  });

  tearDown(() async {
    await db.debugReset();
    db.debugDatabasePath = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SyncService service() => SyncService.forTest(
        http: MockClient((r) async => r.url.host == 'alpha.example'
            ? http.Response(_feed, 200,
                headers: {'content-type': 'application/rss+xml'})
            : http.Response('no', 404)),
        twitter: TwitterService(
            client: MockClient((_) async => http.Response('no', 404)),
            accessToken: () async => 'tok'),
      );

  List<File> storedImages() => tempDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => p.basename(p.dirname(f.path)) == 'images')
      .toList();

  Future<Source> source(String title, {SourceType type = SourceType.rss}) =>
      db.insertSource(Source(
          type: type,
          title: title,
          url: 'https://$title.example/feed'.toLowerCase(),
          createdAt: DateTime(2026, 10, 1).millisecondsSinceEpoch));

  Future<Article> article(Source source, String guid, String content) async {
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: guid,
      title: 'Article $guid',
      url: 'https://${source.title}.example/$guid'.toLowerCase(),
      publishedAt: DateTime(2026, 10, 5).millisecondsSinceEpoch,
      contentMarkdown: content,
      fetched: 1,
      createdAt: DateTime(2026, 10, 5).millisecondsSinceEpoch,
    ));
    return (await db.getArticles()).firstWhere((a) => a.guid == guid);
  }

  test('sync leaves images on the web; opening an article stores them',
      () async {
    await source('Alpha');
    final sync = service();
    await sync.syncAll();
    final stored = (await db.getArticles()).single;
    expect(stored.contentMarkdown, contains('](https://cdn.example/a.png)'));
    expect(imageRequests, 0);
    expect(storedImages(), isEmpty);

    expect(await sync.imagesForReading(stored.id!), isTrue);
    final opened = (await db.getArticle(stored.id!))!.contentMarkdown!;
    final ref = RegExp(r'eink-img://[^)\s]+').firstMatch(opened)!.group(0)!;
    expect(ArchiveStore.remoteOf(ref), 'https://cdn.example/a.png');
    expect(ArchiveStore.localFile(ref)!.existsSync(), isTrue);
    // Nothing left to download: a second open is a no-op.
    expect(await sync.imagesForReading(stored.id!), isFalse);
  });

  test('the cleanup frees images of articles nobody keeps, only those',
      () async {
    final alpha = await source('Alpha');
    final sync = service();
    final archive = ArchiveStore.instance;
    Future<String> localized(String md) => archive.localizeMarkdown(md,
        relDir: '2026/alpha', maxDimension: 1000);
    // Two articles share a picture; each has one of its own.
    final unread = await article(alpha, 'u', await localized(
        '![own](https://cdn.example/own.png?w=600&x=a%20b#top)\n\n'
        '![shared](https://cdn.example/shared.png)'));
    final read = await article(alpha, 'r', await localized(
        '![shared](https://cdn.example/shared.png)\n\n'
        '![mine](https://cdn.example/mine.png)'));
    final toRead = await article(
        alpha, 't', await localized('![](https://cdn.example/later.png)'));
    final highlighted = await article(
        alpha, 'h', await localized('![](https://cdn.example/marked.png)'));
    await db.markArticleRead(read.id!);
    await db.setReadLater(toRead.id!, true);
    await db.insertHighlight(Highlight(
        articleId: highlighted.id!, text: 'x', createdAt: 0));
    expect(storedImages(), hasLength(5));

    await sync.releaseUnusedImages();

    final released = (await db.getArticle(unread.id!))!.contentMarkdown!;
    expect(released,
        contains('![own](https://cdn.example/own.png?w=600&x=a%20b#top)'),
        reason: 'back on the web, the address exactly as it was');
    expect(released, contains('![shared](https://cdn.example/shared.png)'));
    expect(released, isNot(contains('eink-img://')));
    // Its own picture is gone; the one the read article shares stays.
    final names = storedImages().map((f) => p.basename(f.path)).toSet();
    expect(names, hasLength(4));
    for (final kept in [read, toRead, highlighted]) {
      final md = (await db.getArticle(kept.id!))!.contentMarkdown!;
      for (final rel in ArchiveStore.localImages(md)) {
        expect(File(p.join(tempDir.path, rel)).existsSync(), isTrue);
      }
    }
    // The archived .md of the released article points at the web too.
    final md = File(p.join(tempDir.path, '2026', 'alpha',
            '20261005-article-u.md'))
        .readAsStringSync();
    expect(md, contains('](https://cdn.example/shared.png)'));
    // Opening it again brings its pictures back.
    expect(await sync.imagesForReading(unread.id!), isTrue);
    expect(storedImages(), hasLength(5));
  });

  test('the cleanup runs once a day', () async {
    final alpha = await source('Alpha');
    final sync = service();
    await sync.releaseUnusedImages();
    await article(
        alpha,
        'u',
        await ArchiveStore.instance.localizeMarkdown(
            '![](https://cdn.example/a.png)',
            relDir: '2026/alpha',
            maxDimension: 1000));
    await sync.releaseUnusedImages();
    expect(storedImages(), hasLength(1), reason: 'ran less than a day ago');
    await sync.releaseUnusedImages(force: true);
    expect(storedImages(), isEmpty);
  });

  test('inbox articles keep their images, and get them at sync', () async {
    final inbox = await source('Saved', type: SourceType.savedLinks);
    final saved = await article(
        inbox,
        's',
        await ArchiveStore.instance.localizeMarkdown(
            '![](https://cdn.example/a.png)',
            relDir: '2026/saved',
            maxDimension: 1000));
    await service().releaseUnusedImages();
    expect((await db.getArticle(saved.id!))!.contentMarkdown,
        contains('eink-img://'));
    expect(storedImages(), hasLength(1));
  });

  test('an image stored before refs kept their address is lost when freed',
      () async {
    final alpha = await source('Alpha');
    final dir = Directory(p.join(tempDir.path, '2026', 'alpha', 'images'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'old.png')).writeAsStringSync('img');
    final old = await article(
        alpha, 'o', '![](eink-img://2026/alpha/images/old.png)');
    final archive = ArchiveStore.instance;
    expect(await archive.hasLostImages(old.contentMarkdown!), isFalse);
    await service().releaseUnusedImages();
    expect(storedImages(), isEmpty);
    expect(await archive.hasLostImages(old.contentMarkdown!), isTrue,
        reason: 'opening it downloads the article again');
  });
}
