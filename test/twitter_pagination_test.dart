// Bookmarks pagination: the API returns newest-bookmarked-first with no
// date filter, so backfill walks pages until done (resuming across syncs on
// rate limits) and later syncs stop at the first page with nothing new.
// Plus: the feed's author strip treats a Twitter source as a folder of
// accounts.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
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

Map<String, dynamic> _page(List<int> ids, {String? nextToken}) => {
      'data': [
        for (final id in ids)
          {
            'id': '$id',
            'author_id': 'u${id % 2}',
            'text': 'tweet $id',
            'created_at': '2026-07-0${1 + id % 9}T10:00:00.000Z',
          }
      ],
      'includes': {
        'users': [
          {'id': 'u0', 'name': 'Vitalik', 'username': 'vitalikbuterin'},
          {'id': 'u1', 'name': 'Jack', 'username': 'jack'},
        ],
      },
      'meta': {if (nextToken != null) 'next_token': nextToken},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'twitter_user_id': 'me'});
  });

  test('backfill walks all pages; caught-up sync stops at a known page',
      () async {
    final requestedCursors = <String?>[];
    final twitter = TwitterService(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        expect(request.url.queryParameters['max_results'], '100');
        final cursor = request.url.queryParameters['pagination_token'];
        requestedCursors.add(cursor);
        final body = switch (cursor) {
          null => _page([1, 2], nextToken: 'p2'),
          'p2' => _page([3, 4], nextToken: 'p3'),
          'p3' => _page([5, 6]),
          _ => _page([]),
        };
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json'});
      }),
    );

    // Initial backfill: everything is new → all three pages.
    final known = <String>{};
    final items = await twitter.fetchBookmarks(
        hasNewIds: (ids) async => ids.any((id) => !known.contains(id)));
    expect(items.map((t) => t.id),
        containsAll(['1', '2', '3', '4', '5', '6']));
    expect(requestedCursors, [null, 'p2', 'p3']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TwitterService.bookmarksCursorPrefKey), isNull,
        reason: 'backfill completed — no cursor left behind');

    // Caught up: first page all known → exactly one request.
    known.addAll(['1', '2', '3', '4', '5', '6']);
    requestedCursors.clear();
    await twitter.fetchBookmarks(
        hasNewIds: (ids) async => ids.any((id) => !known.contains(id)));
    expect(requestedCursors, [null],
        reason: 'incremental mode stops at the first stale page');
  });

  test('a rate limit mid-backfill keeps the page and resumes next sync',
      () async {
    var calls = 0;
    final twitter = TwitterService(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        calls++;
        final cursor = request.url.queryParameters['pagination_token'];
        if (cursor == null) {
          return http.Response(
              jsonEncode(_page([1], nextToken: 'p2')), 200,
              headers: {'content-type': 'application/json'});
        }
        if (calls == 2) {
          return http.Response('{"title": "Too Many Requests"}', 429);
        }
        return http.Response(jsonEncode(_page([2])), 200,
            headers: {'content-type': 'application/json'});
      }),
    );

    // First sync: page 1 lands, page 2 hits the limit → cursor stored.
    final first = await twitter.fetchBookmarks(
        hasNewIds: (ids) async => true);
    expect(first.map((t) => t.id), ['1']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TwitterService.bookmarksCursorPrefKey), 'p2');

    // Next sync resumes at the stored cursor and finishes the backfill.
    final second = await twitter.fetchBookmarks(
        hasNewIds: (ids) async => false); // stale rule ignored mid-backfill
    expect(second.map((t) => t.id), ['2']);
    expect(prefs.getString(TwitterService.bookmarksCursorPrefKey), isNull);
  });

  testWidgets('a Twitter source expands into an author strip like a folder',
      (tester) async {
    // Database work needs real async — a widget test's zone is fake-async.
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
      for (final spec in [
        ('t1', 'Vitalik', 'thread about proofs'),
        ('t2', 'Jack', 'note on payments'),
        ('t3', 'Vitalik', 'more on rollups'),
      ]) {
        await db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: spec.$1,
          title: spec.$3,
          author: spec.$2,
          contentMarkdown: spec.$3,
          publishedAt: 100,
          createdAt: 100,
          fetched: 1,
        ));
      }
    });

    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: const HomeScreen()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // Select the Twitter source → the author row appears, alphabetical.
    await tester.tap(find.text('Twitter Bookmarks'));
    await tester.pumpAndSettle();
    expect(find.text('Jack'), findsWidgets);
    expect(find.text('Vitalik'), findsWidgets);

    // Narrow to one author: only their bookmarks remain.
    await tester.tap(find.text('Vitalik').first);
    await tester.pumpAndSettle();
    expect(find.text('thread about proofs'), findsOneWidget);
    expect(find.text('more on rollups'), findsOneWidget);
    expect(find.text('note on payments'), findsNothing);

    // Back to All within the source.
    await tester.tap(find.text('All').last);
    await tester.pumpAndSettle();
    expect(find.text('note on payments'), findsOneWidget);
  });
}
