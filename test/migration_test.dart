// Upgrade-path tests: a database created by an OLD app version must migrate
// to the current schema with every source, article and highlight intact.
// Regression for the v0.2.0 lockout: the v8 step created the outbox table
// from a shared constant that v10 had since changed to include kind/payload,
// so upgrading from schema ≤7 hit "duplicate column name: kind", the
// migration transaction rolled back, and the app could not open the (fully
// intact) database — looking like total data loss.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Creates a database file with the exact schema an old version shipped.
Future<String> _legacyDb(int version, Directory dir) async {
  final path = p.join(dir.path, 'v$version.db');
  final db = await databaseFactory.openDatabase(path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE sources (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              type TEXT NOT NULL,
              title TEXT NOT NULL,
              url TEXT NOT NULL,
              description TEXT,
              folder_id INTEGER,
              created_at INTEGER NOT NULL,
              UNIQUE(type, url)
            )
          ''');
          await db.execute('''
            CREATE TABLE folders (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE articles (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_id INTEGER NOT NULL,
              guid TEXT NOT NULL,
              title TEXT NOT NULL,
              author TEXT,
              url TEXT,
              published_at INTEGER,
              summary TEXT,
              content_markdown TEXT,
              url_key TEXT,
              fetched INTEGER NOT NULL DEFAULT 0,
              read INTEGER NOT NULL DEFAULT 0,
              read_later INTEGER NOT NULL DEFAULT 0,
              favorite INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              scroll_position REAL NOT NULL DEFAULT 0,
              scrolled_at INTEGER,
              via_article_id INTEGER,
              UNIQUE(source_id, guid)
            )
          ''');
          await db.execute('''
            CREATE TABLE highlights (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              article_id INTEGER NOT NULL,
              text TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          if (version >= 8) {
            // The outbox as 0.1.15 actually created it (no kind/payload).
            await db.execute('''
              CREATE TABLE outbox (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                quote_tweet_id TEXT,
                created_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT
              )
            ''');
          }
        },
      ));
  await db.insert('sources', {
    'type': 'rss',
    'title': 'My Feed',
    'url': 'https://feed.example',
    'created_at': 1,
  });
  await db.insert('articles', {
    'source_id': 1,
    'guid': 'a1',
    'title': 'Old Article',
    'content_markdown': 'body',
    'fetched': 1,
    'created_at': 1,
  });
  await db.insert('highlights', {
    'article_id': 1,
    'text': 'an old highlight',
    'created_at': 1,
  });
  await db.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  for (final fromVersion in [7, 8]) {
    test('upgrade from schema v$fromVersion keeps all data', () async {
      final dir =
          Directory.systemTemp.createTempSync('einkreader_migration');
      final path = await _legacyDb(fromVersion, dir);

      final app = AppDatabase.instance;
      await app.debugReset();
      app.debugDatabasePath = path;

      // Opening runs the migrations; the old data must all still be there.
      final sources = await app.getSources();
      expect(sources.map((s) => s.title), ['My Feed']);
      expect((await app.getArticles()).map((a) => a.title), ['Old Article']);
      expect((await app.getHighlights()).map((h) => h.text),
          ['an old highlight']);

      // And the new tables/columns work end-to-end.
      await app.insertOutboxItem(const OutboxItem(
          kind: 'nostr', text: 'queued', payload: '{}', createdAt: 2));
      expect((await app.outboxItems()).single.kind, 'nostr');
      await app.insertContact(const Contact(
          name: 'Marc', address: 'marc@example.com', createdAt: 2));
      final highlightId = (await app.getHighlights()).single.id!;
      await app.insertShare(Share(
          highlightId: highlightId, medium: 'profile', createdAt: 2));
      expect((await app.getShares()).single.medium, 'profile');
      await app.debugReset();
    });
  }
}
