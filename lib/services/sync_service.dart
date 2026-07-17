import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'app_log.dart';
import 'extractor.dart';
import 'feed_parser.dart';
import 'archive_store.dart';
import 'nostr_service.dart';
import 'twitter_service.dart';

class SyncProgress {
  final String message;
  final bool running;

  /// True when the database just changed (new articles inserted or content
  /// downloaded), so listeners should refresh the feed mid-sync instead of
  /// waiting for the whole sync to finish.
  final bool reload;

  /// The source currently being updated, so the feed can show a spinner on it.
  /// Null for phase-level messages not tied to one source.
  final int? sourceId;

  /// True when [sourceId] has just finished refreshing (its spinner should
  /// stop), even though the overall sync is still running. Needed because
  /// several sources now refresh concurrently.
  final bool done;

  const SyncProgress(this.message,
      {this.running = true,
      this.reload = false,
      this.sourceId,
      this.done = false});
}

/// Refreshes every source and downloads full article content so everything
/// can be read offline afterwards.
class SyncService {
  SyncService._({http.Client? http, TwitterService? twitter})
      : _http = http ?? _defaultClient(),
        twitter = twitter ?? TwitterService();
  static final SyncService instance = SyncService._();

  /// Builds a [SyncService] wired to fake network/Twitter for tests. The
  /// database and archive singletons are configured separately by the test
  /// (see `AppDatabase.debugDatabasePath` and `ArchiveStore.debugConfigure`).
  @visibleForTesting
  factory SyncService.forTest({
    required http.Client http,
    required TwitterService twitter,
  }) =>
      SyncService._(http: http, twitter: twitter);

  static http.Client _defaultClient() => http.Client();

  final AppDatabase _db = AppDatabase.instance;
  final http.Client _http;
  final TwitterService twitter;
  final nostr = NostrService();
  final _archive = ArchiveStore.instance;

  final progress = StreamController<SyncProgress>.broadcast(sync: true);
  bool _syncing = false;
  bool get isSyncing => _syncing;

  /// Disabled in widget/screenshot tests to keep them offline.
  bool autoSyncOnLaunch = true;

  static const _userAgent =
      'Mozilla/5.0 (compatible; einkreader/0.1; +https://github.com/xdamman/einkreader)';

  /// Most sources fetched at once. Each does an HTTP request plus image
  /// downloads, so this is kept modest to spare low-power e-ink devices.
  static const _maxConcurrentSources = 5;

  /// Runs [tasks] with at most [concurrency] in flight at any time. Dart runs on
  /// a single isolate, so the index counter needs no locking: it is only read
  /// and bumped synchronously between awaits.
  static Future<void> _runBounded(
      int concurrency, List<Future<void> Function()> tasks) async {
    var next = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        final task = tasks[next++];
        await task();
      }
    }

    final workers = min(concurrency, tasks.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  /// Updates all sources, then fetches missing article content.
  /// Returns a human-readable summary.
  Future<String> syncAll() async {
    if (_syncing) {
      await AppLogService.instance.warn('Refresh requested while sync running');
      return 'Sync already running';
    }
    _syncing = true;
    var newArticles = 0;
    final errors = <String>[];
    try {
      final sources = await _db.getSources();
      await AppLogService.instance.info(
        'Refresh started: ${sources.length} sources',
      );
      // Each source is independent, so refresh them concurrently (bounded so a
      // long source list doesn't open dozens of simultaneous connections).
      final counts = List<int>.filled(sources.length, 0);
      await _runBounded(_maxConcurrentSources, [
        for (var i = 0; i < sources.length; i++)
          () async {
            final source = sources[i];
            try {
              counts[i] = await _refreshSource(source);
            } catch (e) {
              errors.add('${source.title}: $e');
              await AppLogService.instance.error(
                'Refresh failed for source #${source.id} ${source.title}: $e',
              );
            }
          },
      ]);
      newArticles = counts.fold(0, (sum, value) => sum + value);
      await _fetchPendingContent();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_sync', DateTime.now().millisecondsSinceEpoch);
    } finally {
      _syncing = false;
      progress.add(const SyncProgress('', running: false));
    }
    final summary =
        newArticles == 0
            ? 'Up to date'
            : '$newArticles new article${newArticles == 1 ? '' : 's'}';
    await AppLogService.instance.info(
      errors.isEmpty
          ? 'Refresh finished: $summary'
          : 'Refresh finished with ${errors.length} error(s): $summary; '
              '${errors.join(' | ')}',
    );
    return errors.isEmpty ? summary : '$summary · ${errors.first}';
  }

  /// Syncs only the given sources (e.g. right after the user adds them), then
  /// downloads any pending content. No-op if a sync is already running.
  Future<void> syncSources(List<Source> sources) async {
    if (_syncing || sources.isEmpty) return;
    _syncing = true;
    try {
      await AppLogService.instance.info(
        'Auto-sync for ${sources.length} new source(s)',
      );
      await _runBounded(_maxConcurrentSources, [
        for (final source in sources)
          () async {
            try {
              await _refreshSource(source);
            } catch (e) {
              await AppLogService.instance.error(
                'Auto-sync failed for source #${source.id} ${source.title}: $e',
              );
            }
          },
      ]);
      await _fetchPendingContent();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_sync', DateTime.now().millisecondsSinceEpoch);
    } finally {
      _syncing = false;
      progress.add(const SyncProgress('', running: false));
    }
  }

  /// Downloads content for a single still-pending article right away (e.g. a
  /// link saved to read later while online). Failures are left pending for
  /// the next sync. Returns true when content landed.
  Future<bool> downloadArticle(int articleId) async {
    final article = await _db.getArticle(articleId);
    if (article == null || article.fetched == 1) return false;
    final changed = await _fetchArticleContent(article);
    progress.add(SyncProgress('', running: _syncing, reload: true));
    return changed;
  }

  /// Quick online probe: resolves a well-known host with a short timeout.
  /// Test seam: set [debugIsOnline] to skip the real lookup.
  Future<bool> isOnline() async {
    final probe = debugIsOnline;
    if (probe != null) return probe();
    try {
      final addresses = await InternetAddress.lookup('one.one.one.one')
          .timeout(const Duration(seconds: 3));
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  Future<bool> Function()? debugIsOnline;

  /// Re-downloads and re-processes a single article's content (the reader's
  /// refresh button), then rewrites its archived markdown. Images are
  /// re-downloaded even when already cached so a previously broken/partial image
  /// is repaired. Throws on failure so the caller can tell the user; the
  /// progress reload still fires either way.
  Future<void> reprocessArticle(int articleId) async {
    final article = await _db.getArticle(articleId);
    if (article == null) return;
    final source = await _db.getSource(article.sourceId);
    progress.add(SyncProgress('Reprocessing…', sourceId: source?.id));
    try {
      final host = Uri.tryParse(article.url ?? '')?.host ?? '';
      final isTweet = host.endsWith('x.com') || host.endsWith('twitter.com');
      if (isTweet && source != null) {
        // Re-fetch the post (picks up edits / new media) and re-localize.
        final item = await twitter.fetchTweet(article.guid);
        final content = await _archive.localizeMarkdown(
          item.text,
          relDir: _relDir(source, article),
          maxDimension: _maxImageDimension,
          overwrite: true,
        );
        await _db.updateArticleContent(article.id!, content, fetched: true);
        await _archive.writeArticle(
            source: source, article: article, markdown: content);
      } else {
        // Re-download and re-extract the linked page.
        final changed = await _fetchArticleContent(article, overwrite: true);
        if (!changed) {
          throw Exception('Could not download — check your connection');
        }
      }
    } catch (e) {
      await AppLogService.instance.error(
        'Reprocess failed for article #$articleId: $e',
      );
      rethrow;
    } finally {
      progress.add(const SyncProgress('', running: false, reload: true));
    }
  }

  /// Relative archive folder for an article filed under its source + date.
  String _relDir(Source source, Article article) => ArchiveStore.sourceDir(
      ArchiveStore.articleDate(article), source.title);

  String _relDirFor(Source source, int? publishedAt, int createdAt) =>
      ArchiveStore.sourceDir(
          DateTime.fromMillisecondsSinceEpoch(publishedAt ?? createdAt),
          source.title);

  /// Fetches one source's items into the database and returns how many new
  /// articles were inserted. Emits progress tagged with the source so the feed
  /// can show a spinner on it and reveal its new articles immediately.
  Future<int> _refreshSource(Source source) async {
    progress.add(SyncProgress('Updating ${source.title}…', sourceId: source.id));
    await AppLogService.instance.info(
      'Refreshing source #${source.id}: ${source.title} '
      '(${source.type.label}) ${source.url}',
    );
    try {
      final inserted = await _syncSource(source);
      await AppLogService.instance.info(
        'Finished refreshing source #${source.id}: $inserted new articles',
      );
      // Surface this source's new articles in the feed right away, before the
      // remaining sources are fetched or any content is downloaded.
      if (inserted > 0) {
        progress.add(SyncProgress('Updating ${source.title}…',
            sourceId: source.id, reload: true));
      }
      return inserted;
    } finally {
      // Stop this source's spinner even though sibling sources may still run.
      progress.add(SyncProgress('', sourceId: source.id, done: true));
    }
  }

  /// Longest screen edge in physical pixels, used to cap stored image size.
  /// The device can rotate, so we take the larger of width/height.
  int get _maxImageDimension {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return 2048;
    final size = views.first.physicalSize;
    final longest = size.width > size.height ? size.width : size.height;
    return longest < 100 ? 2048 : longest.round();
  }

  Future<int> _syncSource(Source source) async {
    switch (source.type) {
      case SourceType.rss:
        return _syncRss(source);
      case SourceType.twitterBookmarks:
        return _insertTweets(source, await twitter.fetchBookmarks());
      case SourceType.twitterLikes:
        // Likes are no longer synced; legacy sources are simply skipped.
        return 0;
      case SourceType.nostrBookmarks:
        return _insertNostrItems(
          source,
          await nostr.fetchBookmarks(source.url),
        );
      case SourceType.nostrLikes:
        return _insertNostrItems(source, await nostr.fetchLikes(source.url));
      case SourceType.savedLinks:
        // Local queue only: its articles are inserted when the user saves a
        // link and downloaded by the pending-content pass below.
        return 0;
    }
  }

  Future<int> _syncRss(Source source) async {
    await AppLogService.instance.info(
      'Loading RSS feed #${source.id}: ${source.url}',
    );
    final response = await _http
        .get(Uri.parse(source.url), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 25));
    await AppLogService.instance.info(
      'Loaded RSS feed #${source.id}: HTTP ${response.statusCode}, '
      '${response.body.length} bytes',
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    // Parsing and converting happen on background isolates: a large feed can
    // take long enough on an e-ink device's CPU to freeze the UI (ANR).
    final xml = response.body;
    final feed = await Isolate.run(() => FeedParser.parse(xml));
    await AppLogService.instance.info(
      'Parsed RSS feed #${source.id}: "${feed.title}", '
      '${feed.items.length} item${feed.items.length == 1 ? '' : 's'}',
    );
    if (source.title.isEmpty || source.title == source.url) {
      await _db.updateSourceTitle(source.id!, feed.title);
    }
    final description = feed.description;
    if (description != null && description != source.description) {
      await _db.updateSourceDescription(source.id!, description);
    }
    var inserted = 0;
    var skipped = 0;
    var fullContent = 0;
    var needsFetch = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in feed.items) {
      // Feeds that ship full content need no page download.
      final hasFullContent = (item.contentHtml ?? '').length > 600;
      if (hasFullContent) {
        fullContent++;
      } else if (item.link != null) {
        needsFetch++;
      }
      // Items already in the database need no conversion or image downloads,
      // so skip them before the expensive steps instead of at insert time.
      if (await _db.articleExists(
          sourceId: source.id!, guid: item.guid, url: item.link)) {
        skipped++;
        continue;
      }
      final published = item.published?.millisecondsSinceEpoch;
      String? markdown;
      if (hasFullContent) {
        final html = item.contentHtml!;
        final converted = await Isolate.run(
            () => ArticleExtractor.convertHtmlToMarkdown(html));
        markdown = await _archive.localizeMarkdown(
          converted,
          relDir: _relDirFor(source, published, now),
          maxDimension: _maxImageDimension,
        );
      }
      final article = Article(
        sourceId: source.id!,
        guid: item.guid,
        title: item.title,
        author: item.author,
        url: item.link,
        publishedAt: published,
        summary: _plainSummary(item.summaryHtml),
        contentMarkdown: markdown,
        fetched: (hasFullContent || item.link == null) ? 1 : 0,
        createdAt: now,
      );
      final isNew = await _db.insertArticleIfNew(article);
      if (isNew) {
        inserted++;
        if (markdown != null) {
          await _archive.writeArticle(
              source: source, article: article, markdown: markdown);
        }
      } else {
        skipped++;
      }
    }
    await AppLogService.instance.info(
      'Processed RSS feed #${source.id}: ${feed.items.length} items, '
      '$inserted inserted, $skipped skipped, $fullContent with feed '
      'content, $needsFetch queued for article download',
    );
    return inserted;
  }

  Future<int> _insertTweets(Source source, List<TweetItem> tweets) async {
    await AppLogService.instance.info(
      'Processing ${tweets.length} tweets for source #${source.id}: '
      '${source.title}',
    );
    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final tweet in tweets) {
      final author =
          tweet.authorName ??
          (tweet.authorUsername != null ? '@${tweet.authorUsername}' : null);
      // A native long-form post is itself the article — keep its full text and
      // don't download a linked page. A short tweet that links to a blog post
      // gets the linked article downloaded (fetched = 0).
      final downloadsArticle = tweet.articleUrl != null && !tweet.isLongForm;
      // Long-form posts keep the tweet permalink so the body stays;
      // others point at the linked article when there is one.
      final url = tweet.isLongForm
          ? tweet.tweetUrl
          : (tweet.articleUrl ?? tweet.tweetUrl);
      // Bookmarks return the same tweets every sync; skip known ones before
      // downloading their images again.
      if (await _db.articleExists(
          sourceId: source.id!, guid: tweet.id, url: url)) {
        continue;
      }
      final published = tweet.createdAt?.millisecondsSinceEpoch;
      // Download any images embedded in the tweet/article so they read offline.
      var content = downloadsArticle ? null : tweet.text;
      if (content != null) {
        content = await _archive.localizeMarkdown(
          content,
          relDir: _relDirFor(source, published, now),
          maxDimension: _maxImageDimension,
        );
      }
      final article = Article(
        sourceId: source.id!,
        guid: tweet.id,
        title: _titleFromText(tweet.text),
        author: author,
        url: url,
        publishedAt: published,
        summary: tweet.text,
        contentMarkdown: content,
        fetched: downloadsArticle ? 0 : 1,
        createdAt: now,
      );
      final isNew = await _db.insertArticleIfNew(article);
      if (isNew) {
        inserted++;
        if (content != null) {
          await _archive.writeArticle(
              source: source, article: article, markdown: content);
        }
      }
    }
    await AppLogService.instance.info(
      'Processed tweets for source #${source.id}: '
      '$inserted inserted, ${tweets.length - inserted} skipped',
    );
    return inserted;
  }

  Future<int> _insertNostrItems(Source source, List<NostrItem> items) async {
    await AppLogService.instance.info(
      'Processing ${items.length} Nostr items for source #${source.id}: '
      '${source.title}',
    );
    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      final isUrlOnly = item.content == item.articleUrl;
      final isNew = await _db.insertArticleIfNew(
        Article(
          sourceId: source.id!,
          guid: item.id,
          title: _titleFromText(
            isUrlOnly ? (item.articleUrl ?? item.content) : item.content,
          ),
          author:
              item.authorPubkey != null
                  ? 'nostr:${item.authorPubkey!.substring(0, 12)}…'
                  : null,
          url: item.articleUrl,
          publishedAt: item.createdAt?.millisecondsSinceEpoch,
          summary: item.content,
          contentMarkdown: item.articleUrl == null ? item.content : null,
          fetched: item.articleUrl == null ? 1 : 0,
          createdAt: now,
        ),
      );
      if (isNew) inserted++;
    }
    await AppLogService.instance.info(
      'Processed Nostr items for source #${source.id}: '
      '$inserted inserted, ${items.length - inserted} skipped',
    );
    return inserted;
  }

  /// Downloads and extracts content for all articles still missing it.
  Future<void> _fetchPendingContent() async {
    final pending = await _db.getUnfetchedArticles();
    await AppLogService.instance.info(
      'Loading pending article content: ${pending.length} articles',
    );
    for (var i = 0; i < pending.length; i++) {
      final article = pending[i];
      final label = 'Downloading articles… ${i + 1}/${pending.length}';
      progress.add(SyncProgress(label, sourceId: article.sourceId));
      final changed = await _fetchArticleContent(article);
      // Refresh the feed as each article finishes downloading so its content
      // and "not downloaded" badge update live.
      if (changed) {
        progress.add(
            SyncProgress(label, sourceId: article.sourceId, reload: true));
      }
    }
  }

  /// Returns true if the article row changed (content downloaded or marked
  /// fetched), false on a network failure that leaves it pending for retry.
  /// When [overwrite] is true (the reader's reprocess button), already-cached
  /// images are re-downloaded rather than reused.
  Future<bool> _fetchArticleContent(Article article,
      {bool overwrite = false}) async {
    final url = article.url;
    if (url == null) {
      await AppLogService.instance.debug(
        'Skipping article #${article.id} content fetch: no URL',
      );
      await _db.markArticleFetched(article.id!);
      return true;
    }
    String body;
    try {
      await AppLogService.instance.debug(
        'Loading article #${article.id}: ${article.title} <$url>',
      );
      final response = await _http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 25));
      await AppLogService.instance.debug(
        'Loaded article #${article.id}: HTTP ${response.statusCode}, '
        '${response.body.length} bytes',
      );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      body = response.body;
    } catch (e) {
      // Network failure: keep fetched = 0 so the next sync retries.
      await AppLogService.instance.warn(
        'Could not load article #${article.id} ${article.title}: $e',
      );
      return false;
    }
    try {
      // Parsing + readability-scoring a full page is CPU-heavy enough to
      // freeze the UI on slow devices, so it runs on a background isolate.
      final markdown =
          await Isolate.run(() => ArticleExtractor.extract(body, baseUrl: url));
      if (markdown != null) {
        final source = await _db.getSource(article.sourceId);
        final relDir = source == null
            ? ArchiveStore.sourceDir(ArchiveStore.articleDate(article), 'web')
            : _relDir(source, article);
        // Pull images onto the device so the article reads fully offline.
        final localized = await _archive.localizeMarkdown(
          markdown,
          relDir: relDir,
          maxDimension: _maxImageDimension,
          overwrite: overwrite,
        );
        var content = localized;
        // Keep the original note/tweet above the extracted article.
        if (article.summary != null &&
            article.contentMarkdown == null &&
            article.summary != article.title) {
          final intro = _plainSummary(article.summary)!;
          if (!_looksLikeHtml(article.summary!) && intro.length < 600) {
            content = '> $intro\n\n---\n\n$localized';
          }
        }
        await _db.updateArticleContent(article.id!, content, fetched: true);
        await AppLogService.instance.debug(
          'Processed article #${article.id}: extracted '
          '${content.length} markdown characters',
        );
        // Tweets/notes get a placeholder title cut from their text, and saved
        // links carry their anchor text or URL; replace it with the real page
        // title once we have it.
        var titled = article;
        if (article.title.endsWith('…') ||
            article.title == article.url ||
            source?.type == SourceType.savedLinks) {
          final pageTitle =
              await Isolate.run(() => ArticleExtractor.extractTitle(body));
          if (pageTitle != null) {
            await _db.updateArticleTitle(article.id!, pageTitle);
            titled = article.copyWith(title: pageTitle);
          }
        }
        // Write the per-article markdown file into the source's archive folder.
        if (source != null) {
          await _archive.writeArticle(
              source: source, article: titled, markdown: content);
        }
      } else {
        // Page had no extractable article; fall back to the summary.
        final fallback =
            _plainSummary(article.summary) ??
            'Could not extract this page. Open it in the browser instead.';
        await _db.updateArticleContent(article.id!, fallback, fetched: true);
        await AppLogService.instance.warn(
          'Processed article #${article.id}: no extractable content, '
          'stored fallback summary',
        );
      }
    } catch (e) {
      await AppLogService.instance.error(
        'Processing failed for article #${article.id} ${article.title}: $e',
      );
      await _db.markArticleFetched(article.id!);
    }
    return true;
  }

  static bool _looksLikeHtml(String text) => text.contains(RegExp(r'<[a-z]+'));

  static String? _plainSummary(String? html) {
    if (html == null) return null;
    final text =
        html
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll('&nbsp;', ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return text.isEmpty ? null : text;
  }

  static String _titleFromText(String text) {
    final clean = text
        // Drop a leading markdown heading marker (e.g. an X Article headline).
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.length <= 90) return clean.isEmpty ? 'Untitled' : clean;
    final cut = clean.substring(0, 90);
    final lastSpace = cut.lastIndexOf(' ');
    return '${cut.substring(0, lastSpace > 40 ? lastSpace : 90)}…';
  }
}
