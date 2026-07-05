import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models.dart';
import '../services/app_log.dart';

/// Single SQLite database holding sources, offline article content and
/// highlights.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  /// Test seam: when set, the database is opened here instead of the default
  /// app location (use `inMemoryDatabasePath` or a temp file with the
  /// sqflite_common_ffi factory).
  @visibleForTesting
  String? debugDatabasePath;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final path =
        debugDatabasePath ?? join(await getDatabasesPath(), 'einkreader.db');
    _db = await openDatabase(
      path,
      version: 5,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  /// Test seam: closes and forgets the open database so the next access reopens
  /// it (e.g. against a fresh temp path between tests).
  @visibleForTesting
  Future<void> debugReset() async {
    await _db?.close();
    _db = null;
  }

  /// Absolute path to the SQLite file, for backup/restore.
  Future<String> databaseFile() async =>
      debugDatabasePath ?? join(await getDatabasesPath(), 'einkreader.db');

  /// Folds the write-ahead log back into the main file so a plain file copy is
  /// a complete, consistent snapshot (used before backing up).
  Future<void> checkpoint() async {
    final db = await database;
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  /// Closes the open connection; the next access reopens it. Used around a
  /// restore, which swaps the underlying file out from under us.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE articles ADD COLUMN read_later INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE articles ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE articles ADD COLUMN url_key TEXT');
      await db.execute(
        'CREATE INDEX idx_articles_url_key ON articles(url_key)',
      );
      // Backfill the canonical key for existing rows so dedup works against
      // already-stored articles.
      final rows = await db.query('articles', columns: ['id', 'url']);
      for (final row in rows) {
        final key = Article.canonicalUrl(row['url'] as String?);
        if (key != null) {
          await db.update(
            'articles',
            {'url_key': key},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE articles ADD COLUMN scroll_position REAL NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE articles ADD COLUMN scrolled_at INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE articles ADD COLUMN via_article_id INTEGER',
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        url TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(type, url)
      )
    ''');
    await db.execute('''
      CREATE TABLE articles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
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
    await db.execute(
      'CREATE INDEX idx_articles_url_key ON articles(url_key)',
    );
    await db.execute('''
      CREATE TABLE highlights (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
        text TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_articles_source ON articles(source_id, published_at)',
    );
  }

  // ---------------------------------------------------------------- sources

  Future<List<Source>> getSources() async {
    final db = await database;
    final rows = await db.query('sources', orderBy: 'created_at ASC');
    await AppLogService.instance.debug(
      'Loaded ${rows.length} source${rows.length == 1 ? '' : 's'}',
    );
    return rows.map(Source.fromMap).toList();
  }

  Future<Source?> getSource(int id) async {
    final db = await database;
    final rows =
        await db.query('sources', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Source.fromMap(rows.first);
  }

  Future<Source?> getSourceByTypeAndUrl(SourceType type, String url) async {
    final db = await database;
    final rows = await db.query(
      'sources',
      where: 'type = ? AND url = ?',
      whereArgs: [type.name, url],
      limit: 1,
    );
    return rows.isEmpty ? null : Source.fromMap(rows.first);
  }

  Future<Source> insertSource(Source source) async {
    final db = await database;
    final id = await db.insert(
      'sources',
      source.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id == 0) {
      final existing = (await getSourceByTypeAndUrl(source.type, source.url))!;
      await AppLogService.instance.info(
        'Source already exists: ${existing.title} '
        '(${existing.type.label}) ${existing.url}',
      );
      return existing;
    }
    final inserted = source.copyWith(id: id);
    await AppLogService.instance.info(
      'Added source #$id: ${inserted.title} '
      '(${inserted.type.label}) ${inserted.url}',
    );
    return inserted;
  }

  Future<void> updateSourceTitle(int id, String title) async {
    final db = await database;
    await db.update(
      'sources',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
    await AppLogService.instance.info('Edited source #$id title: $title');
  }

  Future<void> deleteSource(int id) async {
    final db = await database;
    final sourceRows = await db.query(
      'sources',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final articleCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM articles WHERE source_id = ?',
            [id],
          ),
        ) ??
        0;
    // sqflite does not enable foreign keys by default; delete manually.
    await db.delete(
      'highlights',
      where: 'article_id IN (SELECT id FROM articles WHERE source_id = ?)',
      whereArgs: [id],
    );
    await db.delete('articles', where: 'source_id = ?', whereArgs: [id]);
    await db.delete('sources', where: 'id = ?', whereArgs: [id]);
    final source = sourceRows.isEmpty ? null : Source.fromMap(sourceRows.first);
    await AppLogService.instance.info(
      source == null
          ? 'Removed source #$id with $articleCount articles'
          : 'Removed source #$id: ${source.title} '
              '(${source.type.label}) with $articleCount articles',
    );
  }

  Future<List<SourceType>> sourceTypesOf(List<Source> sources) async =>
      sources.map((s) => s.type).toList();

  // --------------------------------------------------------------- articles

  /// Inserts the article unless a duplicate already exists. A duplicate is
  /// either the same (source, guid) or — across any source — the same
  /// canonical URL, so the same story linked from a feed and a tweet only
  /// appears once. Returns true if a new row was inserted.
  Future<bool> insertArticleIfNew(Article article) async {
    final db = await database;
    final urlKey = article.urlKey;
    if (urlKey != null) {
      final existing = await db.query(
        'articles',
        columns: ['id'],
        where: 'url_key = ?',
        whereArgs: [urlKey],
        limit: 1,
      );
      if (existing.isNotEmpty) return false;
    }
    final id = await db.insert(
      'articles',
      article.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id != 0;
  }

  /// True when an article with this (source, guid) or the same canonical URL
  /// is already stored — the same duplicate rules as [insertArticleIfNew] — so
  /// sync can skip content conversion and image downloads for known items.
  Future<bool> articleExists({
    required int sourceId,
    required String guid,
    String? url,
  }) async {
    final db = await database;
    final urlKey = Article.canonicalUrl(url);
    final rows = await db.query(
      'articles',
      columns: ['id'],
      where: urlKey == null
          ? 'source_id = ? AND guid = ?'
          : '(source_id = ? AND guid = ?) OR url_key = ?',
      whereArgs: urlKey == null
          ? [sourceId, guid]
          : [sourceId, guid, urlKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<Article>> getArticles({
    int? sourceId,
    bool readLaterOnly = false,
    bool favoritesOnly = false,
    int limit = 500,
  }) async {
    final db = await database;
    final where = <String>[
      if (sourceId != null) 'source_id = ?',
      if (readLaterOnly) 'read_later = 1',
      if (favoritesOnly) 'favorite = 1',
    ];
    final rows = await db.query(
      'articles',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: sourceId != null ? [sourceId] : null,
      orderBy: 'COALESCE(published_at, created_at) DESC',
      limit: limit,
    );
    return rows.map(Article.fromMap).toList();
  }

  Future<void> setReadLater(int id, bool readLater) async {
    final db = await database;
    await db.update(
      'articles',
      {'read_later': readLater ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setFavorite(int id, bool favorite) async {
    final db = await database;
    await db.update(
      'articles',
      {'favorite': favorite ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Article?> getArticle(int id) async {
    final db = await database;
    final rows = await db.query(
      'articles',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Article.fromMap(rows.first);
  }

  Future<List<Article>> getUnfetchedArticles() async {
    final db = await database;
    final rows = await db.query(
      'articles',
      where: 'fetched = 0',
      orderBy: 'created_at DESC',
      limit: 200,
    );
    return rows.map(Article.fromMap).toList();
  }

  Future<void> updateArticleContent(
    int id,
    String markdown, {
    required bool fetched,
  }) async {
    final db = await database;
    await db.update(
      'articles',
      {'content_markdown': markdown, 'fetched': fetched ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateArticleTitle(int id, String title) async {
    final db = await database;
    await db.update(
      'articles',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markArticleFetched(int id) async {
    final db = await database;
    await db.update(
      'articles',
      {'fetched': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Sets the read flag and always clears the saved reading position: a read
  /// article restarts from the top, and marking unread resets any progress —
  /// either way the article leaves the Resume reading section.
  Future<void> markArticleRead(int id, {bool read = true}) async {
    final db = await database;
    await db.update(
      'articles',
      {'read': read ? 1 : 0, 'scroll_position': 0.0, 'scrolled_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Saves the reading position. A position > 0 puts an unread article in the
  /// "reading" state (shown under Resume reading); 0 puts it back to plain
  /// unread.
  Future<void> saveScrollPosition(int id, double position) async {
    final db = await database;
    await db.update(
      'articles',
      {
        'scroll_position': position,
        'scrolled_at':
            position > 0 ? DateTime.now().millisecondsSinceEpoch : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<int, int>> unreadCountsBySource() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT source_id, COUNT(*) AS c FROM articles WHERE read = 0 '
      'GROUP BY source_id',
    );
    return {for (final row in rows) row['source_id'] as int: row['c'] as int};
  }

  // ------------------------------------------------------------ saved links

  /// URL marker for the built-in Saved Links source (not a fetchable feed).
  static const savedLinksUrl = 'local:saved-links';

  /// Returns the built-in source that saved links are filed under, creating
  /// it on first use.
  Future<Source> ensureSavedLinksSource() async {
    final existing =
        await getSourceByTypeAndUrl(SourceType.savedLinks, savedLinksUrl);
    if (existing != null) return existing;
    return insertSource(Source(
      type: SourceType.savedLinks,
      title: 'Saved Links',
      url: savedLinksUrl,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Saves a link found inside [viaArticleId] to read later: bookmarked, and
  /// queued for download (fetched = 0) so the next online sync fetches its
  /// content. If the same story is already stored under any source, it is
  /// just bookmarked instead. Returns the queued (or existing) article.
  /// Finds an already-stored article for [url] via its canonical form (same
  /// dedup rule as [insertArticleIfNew]). Null when unknown or unmatched.
  Future<Article?> findArticleByUrl(String url) async {
    final key = Article.canonicalUrl(url);
    if (key == null) return null;
    final db = await database;
    final rows = await db.query(
      'articles',
      where: 'url_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : Article.fromMap(rows.first);
  }

  Future<Article> saveLinkForLater({
    required String url,
    String? title,
    int? viaArticleId,
  }) async {
    final db = await database;
    final existing = await findArticleByUrl(url);
    if (existing != null) {
      await setReadLater(existing.id!, true);
      await AppLogService.instance.info(
        'Link already stored as article #${existing.id}; bookmarked it',
      );
      return (await getArticle(existing.id!))!;
    }
    final source = await ensureSavedLinksSource();
    final now = DateTime.now().millisecondsSinceEpoch;
    final cleanTitle = title?.trim() ?? '';
    final article = Article(
      sourceId: source.id!,
      guid: url,
      // Sync replaces a URL title (and any Saved Links title) with the real
      // page title once the content is downloaded.
      title: cleanTitle.isEmpty ? url : cleanTitle,
      url: url,
      publishedAt: now,
      readLater: 1,
      viaArticleId: viaArticleId,
      createdAt: now,
    );
    final id = await db.insert(
      'articles',
      article.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await AppLogService.instance.info(
      'Saved link for later as article #$id: $url (from #$viaArticleId)',
    );
    if (id != 0) return (await getArticle(id))!;
    // Lost a race with an identical guid; bookmark the existing row.
    final rows = await db.query(
      'articles',
      where: 'source_id = ? AND guid = ?',
      whereArgs: [source.id, url],
      limit: 1,
    );
    final raced = Article.fromMap(rows.first);
    await setReadLater(raced.id!, true);
    return (await getArticle(raced.id!))!;
  }

  // ------------------------------------------------------------- highlights

  Future<int> insertHighlight(Highlight highlight) async {
    final db = await database;
    return db.insert('highlights', highlight.toMap()..remove('id'));
  }

  Future<void> deleteHighlight(int id) async {
    final db = await database;
    await db.delete('highlights', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Highlight>> getHighlights({int? articleId}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT h.*, a.title AS article_title
      FROM highlights h JOIN articles a ON a.id = h.article_id
      ${articleId != null ? 'WHERE h.article_id = ?' : ''}
      ORDER BY h.created_at DESC
    ''', articleId != null ? [articleId] : null);
    return rows.map(Highlight.fromMap).toList();
  }
}
