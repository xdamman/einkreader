// End-to-end tests for SyncService against a real (in-temp) SQLite database and
// archive, with the network and Twitter faked. Covers: a Twitter source pulling
// in new items and de-duplicating on a second sync, and the reader's "Reload &
// reprocess" button repairing a stale tweet (re-downloading its image) and a
// web article that previously stored an extraction fallback.
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

const _twitterUserId = '99';
const _author = {'id': '7', 'name': 'Ada', 'username': 'ada'};

/// A MockClient that always 404s; used when a test exercises no real HTTP.
http.Client _no = MockClient((_) async => http.Response('no', 404));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final db = AppDatabase.instance;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('eink_sync_test');
    db.debugDatabasePath = p.join(tempDir.path, 'test.db');
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {'twitter_user_id': _twitterUserId});
  });

  tearDown(() async {
    await db.debugReset();
    db.debugDatabasePath = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Configures the archive at the temp dir with [imageClient] for downloads.
  void useArchive(http.Client imageClient) => ArchiveStore.instance
      .debugConfigure(basePath: tempDir.path, client: imageClient);

  Map<String, dynamic> bookmarks(List<Map<String, dynamic>> tweets) => {
        'data': tweets,
        'includes': {
          'users': [_author],
        },
      };

  test('a Twitter source pulls in new items and dedups on the next sync',
      () async {
    useArchive(_no);
    await db.insertSource(Source(
      type: SourceType.twitterBookmarks,
      title: 'Bookmarks',
      url: 'ada',
      createdAt: DateTime(2026, 6, 1).millisecondsSinceEpoch,
    ));

    final twitterClient = MockClient((request) async {
      if (request.url.path.endsWith('/users/$_twitterUserId/bookmarks')) {
        return http.Response(
            jsonEncode(bookmarks([
              {
                'id': '1',
                'author_id': _author['id'],
                'created_at': '2026-06-01T10:00:00.000Z',
                'text': 'first thought',
              },
              {
                'id': '2',
                'author_id': _author['id'],
                'created_at': '2026-06-02T10:00:00.000Z',
                'text': 'second thought',
              },
            ])),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final sync = SyncService.forTest(
      http: _no,
      twitter: TwitterService(
          client: twitterClient, accessToken: () async => 'tok'),
    );

    await sync.syncAll();
    expect(await db.getArticles(), hasLength(2));

    // A second sync with the same bookmarks inserts nothing new.
    await sync.syncAll();
    expect(await db.getArticles(), hasLength(2));
  });

  test('reprocess repairs a stale tweet and re-downloads its image', () async {
    var tweetText = 'Caption v1\n\n![](https://cdn/img.jpg)';
    var imageBytes = utf8.encode('imgv1');

    final imageClient = MockClient((request) async =>
        http.Response.bytes(imageBytes, 200,
            headers: {'content-type': 'image/jpeg'}));
    useArchive(imageClient);

    await db.insertSource(Source(
      type: SourceType.twitterBookmarks,
      title: 'Bookmarks',
      url: 'ada',
      createdAt: DateTime(2026, 6, 1).millisecondsSinceEpoch,
    ));

    final twitterClient = MockClient((request) async {
      final path = request.url.path;
      final tweet = {
        'id': 'T1',
        'author_id': _author['id'],
        'created_at': '2026-06-05T10:00:00.000Z',
        'text': tweetText,
      };
      if (path.endsWith('/users/$_twitterUserId/bookmarks')) {
        return http.Response(jsonEncode(bookmarks([tweet])), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/tweets/T1')) {
        return http.Response(
            jsonEncode({
              'data': tweet,
              'includes': {
                'users': [_author]
              }
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final sync = SyncService.forTest(
      http: _no,
      twitter: TwitterService(
          client: twitterClient, accessToken: () async => 'tok'),
    );

    await sync.syncAll();
    final stored = (await db.getArticles()).single;
    expect(stored.contentMarkdown, contains('Caption v1'));
    expect(_imageBytes(tempDir), utf8.encode('imgv1'));

    // The post is edited and its image replaced; reprocess must pick both up.
    tweetText = 'Caption v2\n\n![](https://cdn/img.jpg)';
    imageBytes = utf8.encode('imgv2');
    await sync.reprocessArticle(stored.id!);

    final reprocessed = await db.getArticle(stored.id!);
    expect(reprocessed!.contentMarkdown, contains('Caption v2'));
    // The same URL hashes to the same file, which overwrite replaced in place.
    expect(_imageBytes(tempDir), utf8.encode('imgv2'));
  });

  test('reprocess re-extracts a web article that stored a fallback', () async {
    useArchive(_no);
    final source = await db.insertSource(Source(
      type: SourceType.rss,
      title: 'News',
      url: 'https://news.example.com/feed',
      createdAt: DateTime(2026, 6, 1).millisecondsSinceEpoch,
    ));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'story-1',
      title: 'A Story',
      url: 'https://news.example.com/story',
      publishedAt: DateTime(2026, 6, 6).millisecondsSinceEpoch,
      contentMarkdown:
          'Could not extract this page. Open it in the browser instead.',
      fetched: 1,
      createdAt: DateTime(2026, 6, 6).millisecondsSinceEpoch,
    ));
    final article = (await db.getArticles(sourceId: source.id)).single;

    final paragraph = 'Sentence with enough length to count. ' * 5;
    final html = '<html><head><title>The Story</title></head><body>'
        '<article><h1>The Story</h1><p>$paragraph</p><p>$paragraph</p>'
        '</article></body></html>';
    final pageClient = MockClient((request) async {
      if (request.url.toString() == 'https://news.example.com/story') {
        return http.Response(html, 200,
            headers: {'content-type': 'text/html'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final sync = SyncService.forTest(
      http: pageClient,
      twitter: TwitterService(client: _no, accessToken: () async => 'tok'),
    );

    await sync.reprocessArticle(article.id!);

    final reprocessed = await db.getArticle(article.id!);
    expect(reprocessed!.contentMarkdown, contains('# The Story'));
    expect(reprocessed.contentMarkdown, isNot(contains('Could not extract')));
  });

  test('reprocess throws when the download fails', () async {
    useArchive(_no);
    final source = await db.insertSource(Source(
      type: SourceType.rss,
      title: 'News',
      url: 'https://news.example.com/feed',
      createdAt: DateTime(2026, 6, 1).millisecondsSinceEpoch,
    ));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'story-1',
      title: 'A Story',
      url: 'https://news.example.com/story',
      fetched: 0,
      createdAt: DateTime(2026, 6, 6).millisecondsSinceEpoch,
    ));
    final article = (await db.getArticles(sourceId: source.id)).single;

    final failingClient =
        MockClient((_) async => http.Response('server error', 500));
    final sync = SyncService.forTest(
      http: failingClient,
      twitter: TwitterService(client: _no, accessToken: () async => 'tok'),
    );

    await expectLater(
        sync.reprocessArticle(article.id!), throwsA(isA<Exception>()));
  });

  test(
      'a long-form tweet that announces a link fetches the linked story, '
      'keeping the note as a quoted intro', () async {
    useArchive(_no);
    await db.insertSource(Source(
      type: SourceType.twitterBookmarks,
      title: 'Bookmarks',
      url: 'ada',
      createdAt: DateTime(2026, 8, 1).millisecondsSinceEpoch,
    ));

    const noteText = 'BIG NEW piece by me.\n'
        'A few years ago I would have said it was too broad. '
        'But this year, I decided to do it.\n'
        'https://t.co/wip\n'
        'The central drama of the modern world is innovation '
        'against suffering.';
    final tweet = {
      'id': 'N1',
      'author_id': _author['id'],
      'created_at': '2026-08-11T10:00:00.000Z',
      'text': 'BIG NEW piece by me…',
      'note_tweet': {
        'text': noteText,
        'entities': {
          'urls': [
            {
              'url': 'https://t.co/wip',
              'expanded_url':
                  'https://worksinprogress.example/future-of-medicine/',
            }
          ]
        },
      },
    };
    final twitterClient = MockClient((request) async {
      if (request.url.path.endsWith('/users/$_twitterUserId/bookmarks')) {
        return http.Response(jsonEncode(bookmarks([tweet])), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final page = '<html><head><title>The Future of Medicine</title></head>'
        '<body><article>'
        '<p>${'Medicine has advanced enormously in the last century. ' * 4}</p>'
        '<p>${'Yet millions still suffer from diseases we could treat. ' * 4}</p>'
        '</article></body></html>';
    final web = MockClient((request) async =>
        request.url.host == 'worksinprogress.example'
            ? http.Response(page, 200,
                headers: {'content-type': 'text/html; charset=utf-8'})
            : http.Response('no', 404));
    final sync = SyncService.forTest(
      http: web,
      twitter: TwitterService(
          client: twitterClient, accessToken: () async => 'tok'),
    );

    await sync.syncAll();

    final article = (await db.getArticles()).single;
    expect(article.url, 'https://worksinprogress.example/future-of-medicine/');
    expect(article.title, 'The Future of Medicine');
    expect(article.contentMarkdown, contains('> BIG NEW piece by me.'),
        reason: 'the note survives above the article as a quoted intro');
    expect(article.contentMarkdown, contains('Medicine has advanced'));
  });

  test(
      'reprocess repoints an already-saved link-share bookmark at the '
      'linked story', () async {
    useArchive(_no);
    await db.insertSource(Source(
      type: SourceType.twitterBookmarks,
      title: 'Bookmarks',
      url: 'ada',
      createdAt: DateTime(2026, 8, 1).millisecondsSinceEpoch,
    ));
    // Stored the old way: the note is the article, the link never fetched.
    final source = (await db.getSources()).single;
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'N3',
      title: 'BIG NEW piece by me…',
      url: 'https://x.com/ada/status/N3',
      summary: 'old note',
      contentMarkdown: 'old note',
      fetched: 1,
      createdAt: DateTime(2026, 8, 11).millisecondsSinceEpoch,
    ));

    final tweet = {
      'id': 'N3',
      'author_id': _author['id'],
      'created_at': '2026-08-11T10:00:00.000Z',
      'text': 'BIG NEW piece by me…',
      'note_tweet': {
        'text': 'BIG NEW piece by me.\nhttps://t.co/wip\nRead it.',
        'entities': {
          'urls': [
            {
              'url': 'https://t.co/wip',
              'expanded_url':
                  'https://worksinprogress.example/future-of-medicine/',
            }
          ]
        },
      },
    };
    final twitterClient = MockClient((request) async =>
        request.url.path.endsWith('/tweets/N3')
            ? http.Response(
                jsonEncode({
                  'data': tweet,
                  'includes': {
                    'users': [_author]
                  }
                }),
                200,
                headers: {'content-type': 'application/json'})
            : http.Response('unexpected ${request.url}', 404));
    final page = '<html><head><title>The Future of Medicine</title></head>'
        '<body><article>'
        '<p>${'Medicine has advanced enormously in the last century. ' * 4}</p>'
        '<p>${'Yet millions still suffer from diseases we could treat. ' * 4}</p>'
        '</article></body></html>';
    final web = MockClient((request) async =>
        request.url.host == 'worksinprogress.example'
            ? http.Response(page, 200,
                headers: {'content-type': 'text/html; charset=utf-8'})
            : http.Response('no', 404));
    final sync = SyncService.forTest(
      http: web,
      twitter: TwitterService(
          client: twitterClient, accessToken: () async => 'tok'),
    );

    final saved = (await db.getArticles()).single;
    await sync.reprocessArticle(saved.id!);

    final article = await db.getArticle(saved.id!);
    expect(article!.url,
        'https://worksinprogress.example/future-of-medicine/');
    expect(article.title, 'The Future of Medicine');
    expect(article.contentMarkdown, contains('> BIG NEW piece by me.'));
    expect(article.contentMarkdown, contains('Medicine has advanced'));
  });

  test('a genuinely long note with a link stays the article itself', () async {
    useArchive(_no);
    await db.insertSource(Source(
      type: SourceType.twitterBookmarks,
      title: 'Bookmarks',
      url: 'ada',
      createdAt: DateTime(2026, 8, 1).millisecondsSinceEpoch,
    ));

    final essay = '${'A long essay paragraph with plenty of substance. ' * 15}'
        'https://t.co/ref for context.';
    final tweet = {
      'id': 'N2',
      'author_id': _author['id'],
      'created_at': '2026-08-12T10:00:00.000Z',
      'text': 'A long essay…',
      'note_tweet': {
        'text': essay,
        'entities': {
          'urls': [
            {
              'url': 'https://t.co/ref',
              'expanded_url': 'https://blog.example.com/reference',
            }
          ]
        },
      },
    };
    final twitterClient = MockClient((request) async {
      if (request.url.path.endsWith('/users/$_twitterUserId/bookmarks')) {
        return http.Response(jsonEncode(bookmarks([tweet])), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('unexpected ${request.url}', 404);
    });
    final sync = SyncService.forTest(
      http: _no,
      twitter: TwitterService(
          client: twitterClient, accessToken: () async => 'tok'),
    );

    await sync.syncAll();

    final article = (await db.getArticles()).single;
    expect(article.url, contains('x.com/ada/status/N2'),
        reason: 'the note is the article; no page download');
    expect(article.contentMarkdown, contains('A long essay paragraph'));
  });
}

/// Reads the single archived image's bytes from the temp archive (asserts there
/// is exactly one), so a test can check that reprocess overwrote it.
List<int> _imageBytes(Directory base) {
  final files = base
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => p.basename(p.dirname(f.path)) == 'images')
      .toList();
  expect(files, hasLength(1), reason: 'expected exactly one stored image');
  return files.single.readAsBytesSync();
}
