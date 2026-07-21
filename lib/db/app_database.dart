import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models.dart';
import '../services/app_log.dart';

/// Per-source article statistics shown in the sources screen.
class SourceStats {
  final int downloaded;
  final int read;
  final int contentBytes;
  final int highlights;

  const SourceStats({
    this.downloaded = 0,
    this.read = 0,
    this.contentBytes = 0,
    this.highlights = 0,
  });

  SourceStats withHighlights(int count) => SourceStats(
        downloaded: downloaded,
        read: read,
        contentBytes: contentBytes,
        highlights: count,
      );
}

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
      version: 10,
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
    if (oldVersion < 6) {
      await db.execute(_createFoldersSql);
      await db.execute('ALTER TABLE sources ADD COLUMN folder_id INTEGER');
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE sources ADD COLUMN description TEXT');
    }
    if (oldVersion < 8) {
      await db.execute(_createOutboxSql);
    }
    if (oldVersion < 9) {
      await db.execute('ALTER TABLE highlights ADD COLUMN comment TEXT');
      await db.execute(
        'ALTER TABLE highlights ADD COLUMN shared INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 10) {
      await db.execute(
        "ALTER TABLE outbox ADD COLUMN kind TEXT NOT NULL DEFAULT 'tweet'",
      );
      await db.execute('ALTER TABLE outbox ADD COLUMN payload TEXT');
    }
  }

  static const _createOutboxSql = '''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL DEFAULT 'tweet',
        text TEXT NOT NULL,
        quote_tweet_id TEXT,
        payload TEXT,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''';

  static const _createFoldersSql = '''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''';

  Future<void> _onCreate(Database db, int version) async {
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
    await db.execute(_createFoldersSql);
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
        comment TEXT,
        shared INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_articles_source ON articles(source_id, published_at)',
    );
    await db.execute(_createOutboxSql);
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

  Future<void> updateSourceDescription(int id, String description) async {
    final db = await database;
    await db.update(
      'sources',
      {'description': description},
      where: 'id = ?',
      whereArgs: [id],
    );
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

  // ---------------------------------------------------------------- folders

  Future<List<Folder>> getFolders() async {
    final db = await database;
    final rows =
        await db.query('folders', orderBy: 'title COLLATE NOCASE ASC');
    return rows.map(Folder.fromMap).toList();
  }

  Future<Folder> insertFolder(String title) async {
    final db = await database;
    final folder = Folder(
      title: title,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await db.insert('folders', folder.toMap()..remove('id'));
    await AppLogService.instance.info('Added folder #$id: $title');
    return folder.copyWith(id: id);
  }

  Future<void> renameFolder(int id, String title) async {
    final db = await database;
    await db.update(
      'folders',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
    await AppLogService.instance.info('Renamed folder #$id: $title');
  }

  /// Deletes a folder. Its sources either move to the top level (default) or
  /// are deleted too — with their articles and highlights — when
  /// [deleteSources] is true.
  Future<void> deleteFolder(int id, {bool deleteSources = false}) async {
    final db = await database;
    final members = await db.query(
      'sources',
      columns: ['id'],
      where: 'folder_id = ?',
      whereArgs: [id],
    );
    if (deleteSources) {
      for (final row in members) {
        await deleteSource(row['id'] as int);
      }
    } else {
      await db.update(
        'sources',
        {'folder_id': null},
        where: 'folder_id = ?',
        whereArgs: [id],
      );
    }
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
    await AppLogService.instance.info(
      'Removed folder #$id (${members.length} sources '
      '${deleteSources ? 'deleted' : 'moved to top level'})',
    );
  }

  /// Moves a source into [folderId], or to the top level when null.
  Future<void> setSourceFolder(int sourceId, int? folderId) async {
    final db = await database;
    await db.update(
      'sources',
      {'folder_id': folderId},
      where: 'id = ?',
      whereArgs: [sourceId],
    );
  }

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

  /// Per-source article statistics for the sources screen. Size counts the
  /// stored markdown text (images on disk are not included).
  Future<Map<int, SourceStats>> sourceStats() async {
    final db = await database;
    final stats = <int, SourceStats>{};
    final rows = await db.rawQuery('''
      SELECT source_id,
             SUM(CASE WHEN fetched = 1 THEN 1 ELSE 0 END) AS downloaded,
             SUM(CASE WHEN read = 1 THEN 1 ELSE 0 END) AS read,
             SUM(LENGTH(COALESCE(content_markdown, ''))) AS bytes
      FROM articles GROUP BY source_id
    ''');
    for (final row in rows) {
      stats[row['source_id'] as int] = SourceStats(
        downloaded: (row['downloaded'] as int?) ?? 0,
        read: (row['read'] as int?) ?? 0,
        contentBytes: (row['bytes'] as int?) ?? 0,
      );
    }
    final highlightRows = await db.rawQuery('''
      SELECT a.source_id AS source_id, COUNT(*) AS c
      FROM highlights h JOIN articles a ON a.id = h.article_id
      GROUP BY a.source_id
    ''');
    for (final row in highlightRows) {
      final id = row['source_id'] as int;
      stats[id] = (stats[id] ?? const SourceStats())
          .withHighlights(row['c'] as int);
    }
    return stats;
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

  /// The article an imported highlight belongs to: matched by exact title,
  /// or — when its article is gone (e.g. a removed source) — a minimal
  /// placeholder under Saved Links carrying the title and the highlight text
  /// as content, so the highlight stays attributed and readable.
  Future<Article> articleForImportedHighlight(
      String title, String contentMarkdown) async {
    final db = await database;
    final rows = await db.query(
      'articles',
      where: 'title = ?',
      whereArgs: [title],
      limit: 1,
    );
    if (rows.isNotEmpty) return Article.fromMap(rows.first);
    final source = await ensureSavedLinksSource();
    final now = DateTime.now().millisecondsSinceEpoch;
    final guid = 'imported-highlights:$title';
    final id = await db.insert(
      'articles',
      Article(
        sourceId: source.id!,
        guid: guid,
        title: title,
        contentMarkdown: contentMarkdown,
        fetched: 1,
        read: 1,
        publishedAt: now,
        createdAt: now,
      ).toMap()
        ..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id != 0) return (await getArticle(id))!;
    final existing = await db.query(
      'articles',
      where: 'source_id = ? AND guid = ?',
      whereArgs: [source.id, guid],
      limit: 1,
    );
    return Article.fromMap(existing.first);
  }

  // ---------------------------------------------------------------- outbox

  Future<List<OutboxItem>> outboxItems() async {
    final db = await database;
    final rows = await db.query('outbox', orderBy: 'created_at ASC');
    return rows.map(OutboxItem.fromMap).toList();
  }

  Future<OutboxItem> insertOutboxItem(OutboxItem item) async {
    final db = await database;
    final id = await db.insert('outbox', item.toMap()..remove('id'));
    return OutboxItem.fromMap((await db.query('outbox',
            where: 'id = ?', whereArgs: [id], limit: 1))
        .first);
  }

  Future<void> deleteOutboxItem(int id) async {
    final db = await database;
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  /// Records one more failed send attempt for a queued item.
  Future<void> recordOutboxAttempt(int id, String error) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1, last_error = ? '
      'WHERE id = ?',
      [error, id],
    );
  }

  // ------------------------------------------------------------- highlights

  Future<int> insertHighlight(Highlight highlight) async {
    final db = await database;
    return db.insert('highlights', highlight.toMap()..remove('id'));
  }

  /// Inserts unless the article already has a highlight with this exact text
  /// (e.g. the same selection shared twice). Returns true when inserted.
  Future<bool> insertHighlightIfNew(Highlight highlight) async {
    final db = await database;
    final existing = await db.query(
      'highlights',
      columns: ['id'],
      where: 'article_id = ? AND text = ?',
      whereArgs: [highlight.articleId, highlight.text],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;
    await insertHighlight(highlight);
    return true;
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
