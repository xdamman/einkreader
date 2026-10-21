import 'dart:async';

import 'dart:convert';

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

/// Grouped results of a universal [AppDatabase.search] over everything the
/// reader stores. Highlights always render above articles, which render above
/// sources (the reader's explicit rule); within each list the order is the
/// ranking computed in Dart by [AppDatabase.search].
class SearchResults {
  final List<Highlight> highlights;

  /// Matched articles WITHOUT their content (search never loads the full
  /// text; open an article by id to read it).
  final List<Article> articles;
  final List<Source> sources;

  /// Article id → a stretch of its body around the first match, for those
  /// whose match is in the body.
  final Map<int, String> snippets;

  const SearchResults({
    this.highlights = const [],
    this.articles = const [],
    this.sources = const [],
    this.snippets = const {},
  });

  bool get isEmpty =>
      highlights.isEmpty && articles.isEmpty && sources.isEmpty;
}

/// Single SQLite database holding sources, offline article content and
/// highlights.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  /// The profile whose data all scoped queries return. Set by
  /// ProfileService whenever the active profile resolves or switches; the
  /// legacy single profile is 'default'.
  String activeProfile = 'default';

  /// Subquery fragment limiting article rows to the active profile.
  String get _profileSources =>
      'source_id IN (SELECT id FROM sources WHERE profile_id = ?)';

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
      version: 16,
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
    // A restored file may lack the index: rebuilt on the next search.
    _ftsReady = false;
  }

  /// Adds a column unless the table already has it. Every ADD COLUMN
  /// migration must go through this: a step may run against a table that a
  /// LATER step's shape already includes (the v0.2.0 lockout: step 8 created
  /// the outbox from a shared constant step 10 had since extended, so the
  /// duplicate ALTER threw and the whole upgrade rolled back, locking users
  /// out of an intact database).
  Future<void> _addColumnIfMissing(
      Database db, String table, String column, String definition) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    if (info.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _addColumnIfMissing(
          db, 'articles', 'read_later', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(
          db, 'articles', 'favorite', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 3) {
      await _addColumnIfMissing(db, 'articles', 'url_key', 'TEXT');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_articles_url_key ON articles(url_key)',
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
      await _addColumnIfMissing(
          db, 'articles', 'scroll_position', 'REAL NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'articles', 'scrolled_at', 'INTEGER');
    }
    if (oldVersion < 5) {
      await _addColumnIfMissing(db, 'articles', 'via_article_id', 'INTEGER');
    }
    if (oldVersion < 6) {
      // Frozen historical shape: migration steps must never reuse a live
      // constant that later steps may extend.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await _addColumnIfMissing(db, 'sources', 'folder_id', 'INTEGER');
    }
    if (oldVersion < 7) {
      await _addColumnIfMissing(db, 'sources', 'description', 'TEXT');
    }
    if (oldVersion < 8) {
      // Frozen as 0.1.15 shipped it (no kind/payload — step 10 adds those).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          quote_tweet_id TEXT,
          created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT
        )
      ''');
    }
    if (oldVersion < 9) {
      await _addColumnIfMissing(db, 'highlights', 'comment', 'TEXT');
      await _addColumnIfMissing(
          db, 'highlights', 'shared', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 10) {
      await _addColumnIfMissing(
          db, 'outbox', 'kind', "TEXT NOT NULL DEFAULT 'tweet'");
      await _addColumnIfMissing(db, 'outbox', 'payload', 'TEXT');
    }
    if (oldVersion < 11) {
      await db.execute(_createContactsSql);
      await db.execute(_createSharesSql);
    }
    if (oldVersion < 12) {
      // Profiles namespace their sources (articles/highlights follow via
      // source_id). The original table's UNIQUE(type, url) must widen to
      // include profile_id, which SQLite only allows via a rebuild —
      // guarded and id-preserving (articles reference source ids).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sources_v12 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          url TEXT NOT NULL,
          description TEXT,
          folder_id INTEGER,
          profile_id TEXT NOT NULL DEFAULT 'default',
          created_at INTEGER NOT NULL,
          UNIQUE(type, url, profile_id)
        )
      ''');
      await db.execute(
        'INSERT OR IGNORE INTO sources_v12 '
        '(id, type, title, url, description, folder_id, created_at) '
        'SELECT id, type, title, url, description, folder_id, created_at '
        'FROM sources',
      );
      await db.execute('DROP TABLE sources');
      await db.execute('ALTER TABLE sources_v12 RENAME TO sources');
    }
    if (oldVersion < 13) {
      // When each article was read, so the Read tab lists by reading time.
      await _addColumnIfMissing(db, 'articles', 'read_at', 'INTEGER');
    }
    if (oldVersion < 14) {
      // Local copy of the Nostr events and profiles behind Feedback, so it
      // shows instantly and only asks relays for what's new.
      await db.execute(_createNostrEventsSql);
      await db.execute(_createNostrProfilesSql);
    }
    if (oldVersion < 15) {
      // Outbox items refused for good stop being retried.
      await _addColumnIfMissing(
          db, 'outbox', 'held', 'INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 16) {
      // A linked-list post's own page, shared instead of the page it links
      // to; filled in by the next sync of the feed.
      await _addColumnIfMissing(db, 'articles', 'page_url', 'TEXT');
    }
  }

  static const _createNostrEventsSql = '''
      CREATE TABLE IF NOT EXISTS nostr_events (
        id TEXT PRIMARY KEY,
        kind INTEGER NOT NULL,
        pubkey TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        json TEXT NOT NULL
      )
    ''';

  static const _createNostrProfilesSql = '''
      CREATE TABLE IF NOT EXISTS nostr_profiles (
        pubkey TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        fetched_at INTEGER NOT NULL
      )
    ''';

  static const _createContactsSql = '''
      CREATE TABLE IF NOT EXISTS contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        channel TEXT NOT NULL DEFAULT 'email',
        address TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''';

  static const _createSharesSql = '''
      CREATE TABLE IF NOT EXISTS shares (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        highlight_id INTEGER NOT NULL,
        medium TEXT NOT NULL,
        recipient TEXT,
        ref TEXT,
        created_at INTEGER NOT NULL
      )
    ''';

  static const _createOutboxSql = '''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL DEFAULT 'tweet',
        text TEXT NOT NULL,
        quote_tweet_id TEXT,
        payload TEXT,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        held INTEGER NOT NULL DEFAULT 0
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
        profile_id TEXT NOT NULL DEFAULT 'default',
        created_at INTEGER NOT NULL,
        UNIQUE(type, url, profile_id)
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
        read_at INTEGER,
        page_url TEXT,
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
    await db.execute(_createContactsSql);
    await db.execute(_createSharesSql);
    await db.execute(_createNostrEventsSql);
    await db.execute(_createNostrProfilesSql);
  }

  // ---------------------------------------------------------------- sources

  Future<List<Source>> getSources() async {
    final db = await database;
    final rows = await db.query('sources',
        where: 'profile_id = ?',
        whereArgs: [activeProfile],
        orderBy: 'created_at ASC');
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
      where: 'type = ? AND url = ? AND profile_id = ?',
      whereArgs: [type.name, url, activeProfile],
      limit: 1,
    );
    return rows.isEmpty ? null : Source.fromMap(rows.first);
  }

  Future<Source> insertSource(Source source) async {
    final db = await database;
    final id = await db.insert(
      'sources',
      source.toMap()
        ..remove('id')
        ..['profile_id'] = activeProfile,
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
        where: 'url_key = ? AND $_profileSources',
        whereArgs: [urlKey, activeProfile],
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
          : '(source_id = ? AND guid = ?) '
              'OR (url_key = ? AND $_profileSources)',
      whereArgs: urlKey == null
          ? [sourceId, guid]
          : [sourceId, guid, urlKey, activeProfile],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Records a stored feed item's own page ([Article.pageUrl]) as the feed
  /// now gives it. No-op when unchanged.
  Future<void> updateFeedItemPage(
      {required int sourceId,
      required String guid,
      required String? pageUrl}) async {
    final db = await database;
    await db.update(
      'articles',
      {'page_url': pageUrl},
      where: 'source_id = ? AND guid = ? AND page_url IS NOT ?',
      whereArgs: [sourceId, guid, pageUrl],
    );
  }

  /// When an article sorts in lists: its publication date, but never later
  /// than when it arrived. A feed's future-dated (or mis-dated) items would
  /// otherwise sit on top for days and push real news out of sight.
  static const listedAtSql =
      'MIN(COALESCE(published_at, created_at), created_at)';

  /// Every column but the full text, for lists that never show it.
  static const _listColumns = [
    'id', 'source_id', 'guid', 'title', 'author', 'url', 'url_key',
    'published_at', 'summary', 'fetched', 'read', 'read_later', 'favorite',
    'created_at', 'scroll_position', 'scrolled_at', 'via_article_id',
    'read_at', 'page_url',
  ];

  /// Articles newest first (by [listedAtSql]). [withContent] false leaves
  /// out the full text — the home screen lists every article, so it loads
  /// them light and uncapped ([limit] null).
  Future<List<Article>> getArticles({
    int? sourceId,
    bool readLaterOnly = false,
    bool favoritesOnly = false,
    bool withContent = true,
    int? limit = 500,
  }) async {
    final db = await database;
    final where = <String>[
      _profileSources,
      if (sourceId != null) 'source_id = ?',
      if (readLaterOnly) 'read_later = 1',
      if (favoritesOnly) 'favorite = 1',
    ];
    final rows = await db.query(
      'articles',
      columns: withContent ? null : _listColumns,
      where: where.join(' AND '),
      whereArgs: [activeProfile, if (sourceId != null) sourceId],
      orderBy: '$listedAtSql DESC',
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
      where: 'fetched = 0 AND $_profileSources',
      whereArgs: [activeProfile],
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

  /// Repoints an article at a different page (a tweet bookmark that turns
  /// out to be a link share gets the linked article's URL).
  Future<void> updateArticleUrl(int id, String url) async {
    final db = await database;
    await db.update(
      'articles',
      {'url': url},
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
      {
        'read': read ? 1 : 0,
        'read_at': read ? DateTime.now().millisecondsSinceEpoch : null,
        'scroll_position': 0.0,
        'scrolled_at': null,
      },
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
      FROM articles WHERE $_profileSources GROUP BY source_id
    ''', [activeProfile]);
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
      JOIN sources s ON s.id = a.source_id
      WHERE s.profile_id = ?
      GROUP BY a.source_id
    ''', [activeProfile]);
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
      'AND $_profileSources GROUP BY source_id',
      [activeProfile],
    );
    return {for (final row in rows) row['source_id'] as int: row['c'] as int};
  }

  // ------------------------------------------------------------ saved links

  /// URL marker for the built-in Saved Links source (not a fetchable feed).
  static const savedLinksUrl = 'local:saved-links';

  /// Local (non-fetchable) source urls carry the profile suffix so every
  /// profile gets its own built-in Saved Links / Email source.
  String _localUrl(String base) =>
      activeProfile == 'default' ? base : '$base#$activeProfile';

  /// Returns the built-in source that saved links are filed under, creating
  /// it on first use.
  Future<Source> ensureSavedLinksSource() async {
    final url = _localUrl(savedLinksUrl);
    final existing =
        await getSourceByTypeAndUrl(SourceType.savedLinks, url);
    if (existing != null) return existing;
    return insertSource(Source(
      type: SourceType.savedLinks,
      title: 'Saved Links',
      url: url,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// The built-in source holding emails sent to name@einkreader.app,
  /// created on first use.
  /// The built-in Inbox: content emailed to name@einkreader.app. (Named
  /// "Email" before it became a visible, always-present category.)
  Future<Source> ensureEmailSource() async {
    final url = _localUrl('local:email');
    final existing = await getSourceByTypeAndUrl(SourceType.email, url);
    if (existing != null) {
      if (existing.title != 'Email') return existing;
      await updateSourceTitle(existing.id!, 'Inbox');
      return (await getSourceByTypeAndUrl(SourceType.email, url))!;
    }
    return insertSource(Source(
      type: SourceType.email,
      title: 'Inbox',
      url: url,
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
      where: 'url_key = ? AND $_profileSources',
      whereArgs: [key, activeProfile],
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

  /// Records one more failed send attempt for a queued item; [hold] stops
  /// further retries (the refusal is permanent).
  Future<void> recordOutboxAttempt(int id, String error,
      {bool hold = false}) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1, last_error = ?, '
      'held = ? WHERE id = ?',
      [error, hold ? 1 : 0, id],
    );
  }

  /// Every article with images stored on the device, and whether it keeps
  /// them: it's in To read or the Inbox (emails, saved links), read,
  /// favorited, highlighted, or opened since [openedSince] (ms).
  Future<List<({int id, String content, bool keep})>> articlesWithStoredImages(
      {required int openedSince}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT a.id, a.content_markdown,
        (a.read = 1 OR a.read_later = 1 OR a.favorite = 1
          OR COALESCE(a.scrolled_at, 0) > ?
          OR s.type IN ('email', 'savedLinks')
          OR EXISTS (SELECT 1 FROM highlights h WHERE h.article_id = a.id))
          AS keep
      FROM articles a LEFT JOIN sources s ON s.id = a.source_id
      WHERE a.content_markdown LIKE '%eink-img://%'
    ''', [openedSince]);
    return [
      for (final row in rows)
        (
          id: row['id'] as int,
          content: row['content_markdown'] as String,
          keep: (row['keep'] as int? ?? 0) == 1,
        ),
    ];
  }

  /// Replaces an article's text, leaving its download state alone.
  Future<void> updateArticleMarkdown(int id, String markdown) async {
    final db = await database;
    await db.update('articles', {'content_markdown': markdown},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Rewrites stored `eink-img://YYYY/MM/…` image references to the current
  /// year-first layout (`eink-img://YYYY/…`) after an archive tidy moved the
  /// files. Returns how many articles changed.
  Future<int> stripMonthFromImageRefs() async {
    final db = await database;
    final rows = await db.query(
      'articles',
      columns: ['id', 'content_markdown'],
      where: "content_markdown LIKE '%eink-img://%'",
    );
    final legacyRef = RegExp(r'eink-img://((?:19|20)\d{2})/\d{2}/');
    var changed = 0;
    for (final row in rows) {
      final content = row['content_markdown'] as String;
      final updated = content.replaceAllMapped(
          legacyRef, (m) => 'eink-img://${m[1]}/');
      if (updated == content) continue;
      await db.update(
        'articles',
        {'content_markdown': updated},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      changed++;
    }
    return changed;
  }

  // ------------------------------------------------------- profile import

  /// Sources of a specific profile (for the import chooser) — unscoped by
  /// the active profile on purpose.
  Future<List<Source>> getSourcesOf(String profileId) async {
    final db = await database;
    final rows = await db.query('sources',
        where: 'profile_id = ?',
        whereArgs: [profileId],
        orderBy: 'created_at ASC');
    return rows.map(Source.fromMap).toList();
  }

  /// Copies feeds — and their articles and highlights, read state included —
  /// from [fromProfile] into the ACTIVE profile. [onlySourceIds] narrows the
  /// copy (the "customize" flow); null copies everything. Share history is
  /// not copied: it belongs to the original profile. Returns the number of
  /// sources imported.
  Future<int> importProfileData({
    required String fromProfile,
    Set<int>? onlySourceIds,
  }) async {
    final db = await database;
    final sources = await getSourcesOf(fromProfile);
    var imported = 0;
    for (final source in sources) {
      if (onlySourceIds != null && !onlySourceIds.contains(source.id)) {
        continue;
      }
      final newSourceId = await db.insert(
        'sources',
        source.toMap()
          ..remove('id')
          ..['profile_id'] = activeProfile,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (newSourceId == 0) continue; // already imported earlier
      imported++;
      final articles = await db.query('articles',
          where: 'source_id = ?', whereArgs: [source.id]);
      for (final article in articles) {
        final newArticleId = await db.insert(
            'articles',
            Map<String, Object?>.from(article)
              ..remove('id')
              ..['source_id'] = newSourceId);
        final highlights = await db.query('highlights',
            where: 'article_id = ?', whereArgs: [article['id']]);
        for (final highlight in highlights) {
          await db.insert(
              'highlights',
              Map<String, Object?>.from(highlight)
                ..remove('id')
                ..['article_id'] = newArticleId);
        }
      }
    }
    await AppLogService.instance.info(
        'Profile: imported $imported source(s) from $fromProfile');
    return imported;
  }

  // --------------------------------------------------------------- contacts

  Future<List<Contact>> getContacts() async {
    final db = await database;
    final rows =
        await db.query('contacts', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Contact.fromMap).toList();
  }

  Future<Contact> insertContact(Contact contact) async {
    final db = await database;
    final id = await db.insert('contacts', contact.toMap()..remove('id'));
    return Contact.fromMap((await db.query('contacts',
            where: 'id = ?', whereArgs: [id], limit: 1))
        .first);
  }

  Future<void> deleteContact(int id) async {
    final db = await database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  // ----------------------------------------------------------------- shares

  Future<void> insertShare(Share share) async {
    final db = await database;
    await db.insert('shares', share.toMap()..remove('id'));
  }

  /// All shares newest-first, joined with their highlight and article for
  /// the Shared column.
  Future<List<Share>> getShares() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, h.text AS highlight_text, h.comment AS highlight_comment,
             a.title AS article_title, a.id AS article_id
      FROM shares s
      JOIN highlights h ON h.id = s.highlight_id
      JOIN articles a ON a.id = h.article_id
      JOIN sources src ON src.id = a.source_id
      WHERE src.profile_id = ?
      ORDER BY s.created_at DESC
    ''', [activeProfile]);
    return rows.map(Share.fromMap).toList();
  }

  /// Fills in the published event id on a profile share recorded before
  /// the id was known (or reconciled from the relays).
  Future<void> setProfileShareRef(int highlightId, String ref) async {
    final db = await database;
    await db.update(
      'shares',
      {'ref': ref},
      where: "highlight_id = ? AND medium = 'profile' AND ref IS NULL",
      whereArgs: [highlightId],
    );
  }

  /// The published profile event id for this highlight, if it was ever
  /// shared to the profile (used to build the quote permalink).
  Future<String?> profileShareRef(int highlightId) async {
    final db = await database;
    final rows = await db.query(
      'shares',
      columns: ['ref'],
      where: "highlight_id = ? AND medium IN ('profile','link') "
          'AND ref IS NOT NULL',
      whereArgs: [highlightId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['ref'] as String?;
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

  Future<void> updateHighlightComment(int id, String? comment) async {
    final db = await database;
    await db.update(
      'highlights',
      {'comment': (comment ?? '').isEmpty ? null : comment},
      where: 'id = ?',
      whereArgs: [id],
    );
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
      JOIN sources src ON src.id = a.source_id
      WHERE ${articleId != null ? 'h.article_id = ?' : 'src.profile_id = ?'}
      ORDER BY h.created_at DESC
    ''', [articleId ?? activeProfile]);
    return rows.map(Highlight.fromMap).toList();
  }

  // ---------------------------------------------------------------- search

  /// Wraps [term] as a LIKE pattern that matches it as a literal substring:
  /// the SQL wildcards `%` and `_`, and the escape character itself, are
  /// escaped so a query like `100%` searches for the text "100%" rather than
  /// matching every row. Pair with `LIKE ? ESCAPE '\'`.
  static String _likeArg(String term) {
    final escaped = term
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return '%$escaped%';
  }

  /// Builds a WHERE fragment (and its positional args) requiring every term to
  /// match somewhere in [columns] — terms are ANDed, columns within a term are
  /// ORed. [terms] are already lowercased; columns are wrapped in LOWER() so
  /// matching is case-insensitive.
  static (String, List<String>) _matchClause(
      List<String> columns, List<String> terms) {
    final clauses = <String>[];
    final args = <String>[];
    for (final term in terms) {
      final arg = _likeArg(term);
      final ors =
          columns.map((c) => "LOWER($c) LIKE ? ESCAPE '\\'").join(' OR ');
      clauses.add('($ors)');
      for (var i = 0; i < columns.length; i++) {
        args.add(arg);
      }
    }
    return (clauses.join(' AND '), args);
  }

  static bool _anyTermIn(String? value, List<String> terms) {
    if (value == null || value.isEmpty) return false;
    final lower = value.toLowerCase();
    return terms.any(lower.contains);
  }

  /// Weighted relevance of an article for [terms]: a title hit dominates an
  /// author hit, which dominates a summary/content hit; weights sum when
  /// several fields match. Ties are broken by recency in [search].
  static int _articleScore(Article a, List<String> terms, bool bodyHit) {
    var score = 0;
    if (_anyTermIn(a.title, terms)) score += 100;
    if (_anyTermIn(a.author, terms)) score += 80;
    if (bodyHit) score += 10;
    return score;
  }

  /// ~80 characters of context around the first match of any of [terms] in
  /// [raw], or null when none appears.
  static String? snippetAround(String? raw, List<String> terms) {
    if (raw == null || raw.trim().isEmpty) return null;
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lower = flat.toLowerCase();
    int? at;
    for (final term in terms) {
      final i = lower.indexOf(term);
      if (i >= 0 && (at == null || i < at)) at = i;
    }
    if (at == null) return null;
    const pad = 40;
    final start = (at - pad).clamp(0, flat.length);
    final end = (at + pad).clamp(0, flat.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < flat.length ? '…' : '';
    return '$prefix${flat.substring(start, end).trim()}$suffix';
  }

  // ---------------------------------------------------------- search index

  /// Full-text index over article title, author, summary and body, so
  /// search answers from an index instead of reading every article's text.
  /// FTS5 when this device's SQLite has it, else FTS4; when neither exists,
  /// search falls back to scanning with LIKE. Triggers keep it current; a
  /// background pass ([buildSearchIndex]) adds articles stored before it
  /// existed.
  bool _ftsReady = false;
  String _ftsKind = 'fts5';
  Future<void>? _ftsBuilding;

  Future<String?> _createFtsTable(Database db) async {
    final existing = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = 'articles_fts'");
    if (existing.isNotEmpty) {
      return (existing.first['sql'] as String? ?? '').contains('fts5')
          ? 'fts5'
          : 'fts4';
    }
    for (final (kind, sql) in [
      ('fts5', 'CREATE VIRTUAL TABLE articles_fts USING fts5('
          "title, author, summary, body, tokenize = 'unicode61')"),
      ('fts4', 'CREATE VIRTUAL TABLE articles_fts USING fts4('
          'title, author, summary, body, tokenize=unicode61)'),
      ('fts4', 'CREATE VIRTUAL TABLE articles_fts USING fts4('
          'title, author, summary, body)'),
    ]) {
      try {
        await db.execute(sql);
        return kind;
      } catch (_) {
        // Not compiled into this SQLite: try the next.
      }
    }
    return null;
  }

  /// Creates the index (once) and indexes any article not in it yet, in
  /// small batches. Safe to call repeatedly; one pass runs at a time.
  Future<void> buildSearchIndex() => _ftsBuilding ??= _buildSearchIndex();

  Future<void> _buildSearchIndex() async {
    try {
      final db = await database;
      final kind = await _createFtsTable(db);
      if (kind == null) return;
      const cols = 'title, author, summary, body';
      const vals = 'new.title, new.author, new.summary, new.content_markdown';
      await db.execute('CREATE TRIGGER IF NOT EXISTS articles_fts_ai '
          'AFTER INSERT ON articles BEGIN '
          'INSERT INTO articles_fts(rowid, $cols) VALUES (new.id, $vals); END');
      await db.execute('CREATE TRIGGER IF NOT EXISTS articles_fts_ad '
          'AFTER DELETE ON articles BEGIN '
          'DELETE FROM articles_fts WHERE rowid = old.id; END');
      // Only text changes reindex: read flags and scroll positions change
      // constantly.
      await db.execute('CREATE TRIGGER IF NOT EXISTS articles_fts_au '
          'AFTER UPDATE OF title, author, summary, content_markdown '
          'ON articles BEGIN '
          'DELETE FROM articles_fts WHERE rowid = old.id; '
          'INSERT INTO articles_fts(rowid, $cols) VALUES (new.id, $vals); END');
      var total = 0;
      while (true) {
        final added = await db.rawUpdate(
            'INSERT INTO articles_fts(rowid, $cols) '
            'SELECT id, title, author, summary, content_markdown '
            'FROM articles a WHERE NOT EXISTS '
            '(SELECT 1 FROM articles_fts f WHERE f.rowid = a.id) '
            'ORDER BY id DESC LIMIT 100');
        total += added;
        if (added == 0) break;
      }
      _ftsKind = kind;
      _ftsReady = true;
      if (total > 0) {
        await AppLogService.instance
            .info('Search index ($kind): $total articles indexed');
      }
    } catch (e) {
      await AppLogService.instance.warn('Search index unavailable: $e');
    } finally {
      _ftsBuilding = null;
    }
  }

  /// An FTS query for [terms]: every word as a prefix (`dosto*`), all
  /// required. Words are split on anything but letters and digits, so no
  /// user input reaches the query syntax.
  static String? _ftsQuery(List<String> terms) {
    final words = terms
        .expand((t) => t.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    return words.map((w) => '$w*').join(' ');
  }

  /// Matching articles (light: no full text), snippets around body
  /// matches, and which matched outside their title/author.
  Future<(List<Article>, Map<int, String>, Set<int>)> _searchArticles(
      Database db, List<String> terms) async {
    final match = _ftsReady ? _ftsQuery(terms) : null;
    if (!_ftsReady) unawaited(buildSearchIndex());
    final List<Map<String, Object?>> rows;
    if (match != null) {
      rows = await db.rawQuery(
          'SELECT ${_listColumns.join(', ')} FROM articles '
          'WHERE id IN (SELECT rowid FROM articles_fts '
          'WHERE articles_fts MATCH ?) AND $_profileSources',
          [match, activeProfile]);
    } else {
      // No index (yet): scan. Plain LIKE on the body (case-insensitive for
      // ASCII, like LOWER): lowercasing every article's text is slow.
      final clauses = <String>[];
      final args = <String>[];
      for (final term in terms) {
        final arg = _likeArg(term);
        clauses.add("(LOWER(title) LIKE ? ESCAPE '\\' "
            "OR LOWER(COALESCE(author, '')) LIKE ? ESCAPE '\\' "
            "OR LOWER(COALESCE(summary, '')) LIKE ? ESCAPE '\\' "
            "OR content_markdown LIKE ? ESCAPE '\\')");
        args.addAll([arg, arg, arg, arg]);
      }
      rows = await db.rawQuery(
          'SELECT ${_listColumns.join(', ')} FROM articles '
          'WHERE $_profileSources AND (${clauses.join(' AND ')})',
          [activeProfile, ...args]);
    }
    final articles = rows.map(Article.fromMap).toList();
    final snippets = <int, String>{};
    final bodyHit = <int>{};
    final needBody = <int>[];
    for (final article in articles) {
      final inTitle = _anyTermIn(article.title, terms) ||
          _anyTermIn(article.author, terms);
      if (!inTitle) bodyHit.add(article.id!);
      final summary = snippetAround(article.summary, terms);
      if (summary != null) {
        snippets[article.id!] = summary;
      } else if (!inTitle) {
        needBody.add(article.id!);
      }
    }
    // Body snippets only for the first results: reading text is the slow
    // part, and the list shows a screenful at a time.
    final first = terms.first;
    for (var i = 0; i < needBody.length && i < 200; i += 50) {
      final ids = needBody.skip(i).take(50).toList();
      final marks = List.filled(ids.length, '?').join(',');
      // The index's own excerpt matches like the search does (accents,
      // word prefixes); without it, the first literal match of a term.
      final bodies = match != null
          ? await db.rawQuery(
              'SELECT rowid AS id, ${_ftsKind == 'fts5' ? "snippet(articles_fts, 3, '', '', '…', 14)" : "snippet(articles_fts, '', '', '…', 3, 14)"} AS body '
              'FROM articles_fts WHERE articles_fts MATCH ? '
              'AND rowid IN ($marks)',
              [match, ...ids])
          : await db.rawQuery(
              'SELECT id, substr(content_markdown, '
              'max(1, instr(LOWER(content_markdown), ?) - 120), 300) AS body '
              'FROM articles WHERE id IN ($marks) '
              'AND instr(LOWER(content_markdown), ?) > 0',
              [first, ...ids, first]);
      for (final row in bodies) {
        final body = row['body'] as String?;
        final snippet = match != null
            ? body?.replaceAll(RegExp(r'\s+'), ' ').trim()
            : snippetAround(body, terms);
        if (snippet != null && snippet.isNotEmpty) {
          snippets[row['id'] as int] = snippet;
        }
      }
    }
    return (articles, snippets, bodyHit);
  }

  /// Universal search over sources, authors, article titles/content and
  /// highlights (their text and comments). Whitespace splits the query into
  /// terms that are ANDed — every term must match somewhere in a row. Matching
  /// uses SQL LIKE on existing columns (no FTS, no schema change): the corpus
  /// is small and this repo has been burned by migrations. Each result list is
  /// ordered by its ranking, computed here in Dart.
  Future<SearchResults> search(String query) async {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return const SearchResults();
    final db = await database;

    // Highlights: match the highlight text or its comment; join the article
    // title for display, exactly like getHighlights.
    final (hWhere, hArgs) =
        _matchClause(['h.text', "COALESCE(h.comment, '')"], terms);
    final highlightRows = await db.rawQuery('''
      SELECT h.*, a.title AS article_title
      FROM highlights h JOIN articles a ON a.id = h.article_id
      JOIN sources src ON src.id = a.source_id
      WHERE src.profile_id = ? AND ($hWhere)
    ''', [activeProfile, ...hArgs]);
    final highlights = highlightRows.map(Highlight.fromMap).toList();

    final (articles, snippets, bodyHit) = await _searchArticles(db, terms);

    // Sources: title or url (a twitter username lives in the url).
    final (sWhere, sArgs) = _matchClause(['title', 'url'], terms);
    final sourceRows = await db.query('sources',
        where: 'profile_id = ? AND ($sWhere)',
        whereArgs: [activeProfile, ...sArgs]);
    final sources = sourceRows.map(Source.fromMap).toList();

    // Highlights: text match before comment-only match, then newest first.
    highlights.sort((a, b) {
      final ta = _anyTermIn(a.text, terms) ? 1 : 0;
      final tb = _anyTermIn(b.text, terms) ? 1 : 0;
      if (ta != tb) return tb - ta;
      return b.createdAt.compareTo(a.createdAt);
    });

    // Articles: score desc, then most recent.
    int score(Article a) => _articleScore(a, terms, bodyHit.contains(a.id));
    articles.sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      if (byScore != 0) return byScore;
      return b.listedAt.compareTo(a.listedAt);
    });

    // Sources: title match before url-only match, then alphabetical (this
    // user's rule: stable lists are alphabetical, never by relevance count).
    sources.sort((a, b) {
      final ta = _anyTermIn(a.title, terms) ? 1 : 0;
      final tb = _anyTermIn(b.title, terms) ? 1 : 0;
      if (ta != tb) return tb - ta;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return SearchResults(
      highlights: highlights,
      articles: articles,
      sources: sources,
      snippets: snippets,
    );
  }

  // ------------------------------------------------------------ nostr cache

  /// Stores raw Nostr events (deduplicated by id).
  Future<void> saveNostrEvents(Iterable<Map<String, dynamic>> events) async {
    final db = await database;
    final batch = db.batch();
    for (final e in events) {
      final id = e['id'] as String?;
      if (id == null) continue;
      batch.insert(
        'nostr_events',
        {
          'id': id,
          'kind': e['kind'] as int? ?? 0,
          'pubkey': e['pubkey'] as String? ?? '',
          'created_at': e['created_at'] as int? ?? 0,
          'json': jsonEncode(e),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Cached raw events of [kinds].
  Future<List<Map<String, dynamic>>> nostrEvents(List<int> kinds) async {
    final db = await database;
    final rows = await db.query('nostr_events',
        where: 'kind IN (${List.filled(kinds.length, '?').join(',')})',
        whereArgs: kinds);
    return [
      for (final r in rows)
        jsonDecode(r['json'] as String) as Map<String, dynamic>
    ];
  }

  /// Newest cached created_at among [kinds] (null when none cached).
  Future<int?> latestNostrEventAt(List<int> kinds) async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT MAX(created_at) AS latest FROM nostr_events '
        'WHERE kind IN (${List.filled(kinds.length, '?').join(',')})',
        kinds);
    return rows.first['latest'] as int?;
  }

  /// Stores kind-0 metadata JSON per pubkey.
  Future<void> saveNostrProfiles(Map<String, String> jsonByPubkey) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    jsonByPubkey.forEach((pubkey, json) {
      batch.insert('nostr_profiles',
          {'pubkey': pubkey, 'json': json, 'fetched_at': now},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }

  /// Drops the cached Nostr events and profiles (they refill from relays).
  Future<void> clearNostrCache() async {
    final db = await database;
    await db.delete('nostr_events');
    await db.delete('nostr_profiles');
  }

  /// Cached profile metadata JSON by pubkey.
  Future<Map<String, String>> nostrProfiles() async {
    final db = await database;
    final rows = await db.query('nostr_profiles');
    return {for (final r in rows) r['pubkey'] as String: r['json'] as String};
  }
}
