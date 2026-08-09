// Twitter bookmarks: one 100-item fetch, every insert/skip decision logged
// with the author's username (so a "missing" bookmark is one debug-log
// search away), and the feed's author strip — a Twitter source behaves like
// a folder of accounts, collapsing one-off authors into "Others" past 10.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/services/app_log.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'twitter_user_id': 'me'});
  });

  test('fetched pages decode as UTF-8 when no charset is declared', () {
    // Cloudflare-style: UTF-8 bytes, Content-Type without charset. The
    // http package would decode Latin-1 and turn ’ into "â€™" mojibake.
    final curly = http.Response.bytes(
        utf8.encode('Cloudflare’s community'), 200,
        headers: {'content-type': 'text/html'});
    expect(SyncService.decodeBody(curly), 'Cloudflare’s community');

    // An explicit charset is honored as-is.
    final declared = http.Response.bytes(
        utf8.encode('déjà vu'), 200,
        headers: {'content-type': 'text/html; charset=utf-8'});
    expect(SyncService.decodeBody(declared), 'déjà vu');

    // Genuinely non-UTF-8 bytes fall back to the header decoding.
    final latin = http.Response.bytes(
        [0x63, 0x61, 0x66, 0xE9], 200, // "café" in Latin-1
        headers: {'content-type': 'text/html'});
    expect(SyncService.decodeBody(latin), 'café');
  });

  test('bookmark sync logs every decision with the author username',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final db = AppDatabase.instance;
    await db.debugReset();
    final tmp = Directory.systemTemp.createTempSync('einkreader_bmlog');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));

    // An RSS article already holds the link owocki's bookmark points to —
    // the classic silent-skip case, now visible in the log.
    final rss = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://f', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: rss.id!,
      guid: 'r1',
      title: 'Existing Story',
      url: 'https://blog.example.com/post',
      createdAt: 1,
      fetched: 1,
    ));

    final timeline = {
      'data': [
        {
          'id': '100',
          'author_id': 'u1',
          'text': 'fresh thought',
          'created_at': '2026-07-20T10:00:00.000Z',
        },
        {
          'id': '101',
          'author_id': 'u2',
          'text': 'read this https://t.co/x',
          'created_at': '2026-07-20T11:00:00.000Z',
          'entities': {
            'urls': [
              {
                'url': 'https://t.co/x',
                'expanded_url': 'https://blog.example.com/post',
                'display_url': 'blog.example.com/post',
              }
            ]
          },
        },
      ],
      'includes': {
        'users': [
          {'id': 'u1', 'name': 'Jack', 'username': 'jack'},
          {'id': 'u2', 'name': 'Kevin Owocki', 'username': 'owocki'},
        ],
      },
    };
    final twitter = TwitterService(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/users/me/bookmarks')) {
          expect(request.url.queryParameters['max_results'], '100');
          return http.Response(jsonEncode(timeline), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    final sync = SyncService.forTest(
      http: MockClient((request) async => http.Response('x', 404)),
      twitter: twitter,
    )..autoSyncOnLaunch = false;

    final bookmarks = await db.insertSource(Source(
        type: SourceType.twitterBookmarks,
        title: 'Twitter Bookmarks',
        url: 'xdamman',
        createdAt: 0));
    await sync.syncSources([bookmarks]);

    // Jack's bookmark landed; owocki's was skipped by URL dedup — and the
    // log says so, searchable by username.
    final titles = (await db.getArticles(sourceId: bookmarks.id))
        .map((a) => a.title);
    expect(titles, contains('fresh thought'));
    final log =
        (await AppLogService.instance.entries()).map((e) => e.message);
    expect(log, anyElement(contains('@jack')));
    expect(
        log,
        anyElement(allOf(contains('@owocki'),
            contains('same link already saved as "Existing Story"'))));
  });

  testWidgets(
      'author strip collapses one-off authors into Others past 10',
      (tester) async {
    await tester.runAsync(() async {
      SyncService.instance.autoSyncOnLaunch = false;
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      final db = AppDatabase.instance;
      await db.debugReset();
      db.debugDatabasePath = p.join(
          Directory.systemTemp.createTempSync('einkreader_authors').path,
          'test.db');
      final source = await db.insertSource(Source(
          type: SourceType.twitterBookmarks,
          title: 'Twitter Bookmarks',
          url: 'xdamman',
          createdAt: 0));
      // 2 recurring authors (2 bookmarks each) + 10 one-offs = 12 authors.
      var guid = 0;
      Future<void> add(String author, String title) =>
          db.insertArticleIfNew(Article(
            sourceId: source.id!,
            guid: 't${guid++}',
            title: title,
            author: author,
            contentMarkdown: title,
            publishedAt: 100,
            createdAt: 100,
            fetched: 1,
          ));
      await add('Vitalik', 'thread about proofs');
      await add('Vitalik', 'more on rollups');
      await add('Jack', 'note on payments');
      await add('Jack', 'note on nodes');
      for (var i = 0; i < 10; i++) {
        await add('OneOff$i', 'single bookmark $i');
      }
    });

    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const HomeScreen()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Twitter Bookmarks'));
    await tester.pumpAndSettle();

    // Recurring authors get chips; one-offs collapse into Others.
    expect(find.text('Jack'), findsOneWidget);
    expect(find.text('Vitalik'), findsOneWidget);
    expect(find.text('Others'), findsOneWidget);
    expect(find.text('OneOff3'), findsNothing);

    // Others shows exactly the collapsed authors' bookmarks.
    await tester.tap(find.text('Others'));
    await tester.pumpAndSettle();
    expect(find.text('single bookmark 0'), findsOneWidget);
    expect(find.text('thread about proofs'), findsNothing);

    // A named author still narrows normally.
    await tester.tap(find.text('Vitalik'));
    await tester.pumpAndSettle();
    expect(find.text('thread about proofs'), findsOneWidget);
    expect(find.text('single bookmark 0'), findsNothing);
  });
}
