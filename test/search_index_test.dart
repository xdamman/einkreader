// The full-text search index: built over existing articles, kept current
// by triggers (new and edited articles), accent- and case-insensitive,
// word-prefix matching, and fast on a large library.
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
  late Source news;
  // ~20 KB of filler per article, like a real long read.
  final filler = List.filled(400, 'lorem ipsum dolor sit amet consequat '
      'vestibulum ').join();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_fts');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));
    news = await db.insertSource(Source(
        type: SourceType.rss, title: 'News', url: 'https://n', createdAt: 0));
    final database = await db.database;
    final batch = database.batch();
    for (var i = 0; i < 2000; i++) {
      batch.insert('articles', Article(
        sourceId: news.id!,
        guid: 'g$i',
        title: 'Story number $i',
        contentMarkdown: i == 1234
            ? '$filler Les Étudiants de Dostoïevski $filler'
            : filler,
        createdAt: i,
      ).toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  });

  test('indexed search is fast and accent-insensitive', () async {
    // Without the index: a full scan of ~40 MB of text.
    final scanWatch = Stopwatch()..start();
    final scanned = await db.search('dostoïevski');
    scanWatch.stop();
    expect(scanned.articles.single.title, 'Story number 1234');

    await db.buildSearchIndex();
    final watch = Stopwatch()..start();
    final hit = await db.search('etudiants dosto');
    watch.stop();
    expect(hit.articles.single.title, 'Story number 1234');
    expect(hit.snippets.values.single, contains('Dostoïevski'));
    // ignore: avoid_print
    print('scan ${scanWatch.elapsedMilliseconds} ms, '
        'index ${watch.elapsedMilliseconds} ms');
    expect(watch.elapsedMilliseconds, lessThan(scanWatch.elapsedMilliseconds));
    expect(watch.elapsedMilliseconds, lessThan(150));
  });

  test('new and edited articles are found right away', () async {
    await db.insertArticleIfNew(Article(
        sourceId: news.id!,
        guid: 'fresh',
        title: 'Brothers Karamazov',
        author: 'Patrick Collison',
        createdAt: 5000));
    expect((await db.search('karamazov')).articles.single.author,
        'Patrick Collison');
    final id = (await db.search('karamazov')).articles.single.id!;
    await db.updateArticleContent(id, 'Now about Tolstoy', fetched: true);
    expect((await db.search('tolstoy')).articles.single.id, id);
    // Read flags don't touch the index, and still find it.
    await db.setReadLater(id, true);
    expect((await db.search('karamazov')).articles, hasLength(1));
  });
}
