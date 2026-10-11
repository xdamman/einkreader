// The home feed loads every article (light: no full text, no cap) ordered by
// publication date clamped to arrival, so a feed's future-dated items can't
// sit on top and push fresh bookmarks out of sight. Search returns matches
// without their full text but with a snippet around a body hit.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  const hour = 3600 * 1000;
  final now = DateTime(2026, 10, 11, 9).millisecondsSinceEpoch;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_order');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));

    final rss = await db.insertSource(Source(
        type: SourceType.rss, title: 'News', url: 'https://n', createdAt: 0));
    final twitter = await db.insertSource(Source(
        type: SourceType.twitterBookmarks,
        title: 'Twitter Bookmarks',
        url: 'x',
        createdAt: 0));
    // 600 news items stamped a week in the future, fetched yesterday.
    for (var i = 0; i < 600; i++) {
      await db.insertArticleIfNew(Article(
          sourceId: rss.id!,
          guid: 'n$i',
          title: 'Future news $i',
          publishedAt: now + 7 * 24 * hour + i,
          createdAt: now - 24 * hour,
          contentMarkdown: 'body $i'));
    }
    await db.insertArticleIfNew(Article(
        sourceId: twitter.id!,
        guid: 't1',
        title: 'Brothers Karamazov was Einstein\'s favorite novel',
        author: 'Patrick Collison',
        publishedAt: now - 5 * hour,
        createdAt: now,
        summary: 'Brothers Karamazov was Einstein\'s favorite novel',
        contentMarkdown: 'A long thread. Deep inside it mentions Dostoevsky.'));
  });

  test('a fresh bookmark leads the feed over future-dated items', () async {
    final all = await db.getArticles(withContent: false, limit: null);
    expect(all, hasLength(601));
    expect(all.first.title, startsWith('Brothers Karamazov'));
    // Light rows: no full text loaded.
    expect(all.every((a) => a.contentMarkdown == null), isTrue);
    // A future date is shown as the day it arrived.
    final future = all.firstWhere((a) => a.title == 'Future news 0');
    expect(future.listedAt, now - 24 * hour);
  });

  test('search skips the full text but keeps a snippet and the date',
      () async {
    final results = await db.search('dostoevsky');
    final hit = results.articles.single;
    expect(hit.contentMarkdown, isNull);
    expect(hit.publishedAt, now - 5 * hour);
    expect(results.snippets[hit.id], contains('Dostoevsky'));
    // Case-insensitive on the body too.
    expect((await db.search('DOSTOEVSKY')).articles, hasLength(1));
  });
}
