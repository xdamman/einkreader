import 'dart:async';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'app_log.dart';
import 'extractor.dart';
import 'feed_parser.dart';
import 'image_store.dart';
import 'nostr_service.dart';
import 'twitter_service.dart';

class SyncProgress {
  final String message;
  final bool running;
  const SyncProgress(this.message, {this.running = true});
}

/// Refreshes every source and downloads full article content so everything
/// can be read offline afterwards.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final _db = AppDatabase.instance;
  final twitter = TwitterService();
  final nostr = NostrService();
  final _images = ImageStore.instance;

  final progress = StreamController<SyncProgress>.broadcast(sync: true);
  bool _syncing = false;
  bool get isSyncing => _syncing;

  /// Disabled in widget/screenshot tests to keep them offline.
  bool autoSyncOnLaunch = true;

  static const _userAgent =
      'Mozilla/5.0 (compatible; einkreader/0.1; +https://github.com/xdamman/einkreader)';

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
      for (final source in sources) {
        progress.add(SyncProgress('Updating ${source.title}…'));
        try {
          await AppLogService.instance.info(
            'Refreshing source #${source.id}: ${source.title} '
            '(${source.type.label}) ${source.url}',
          );
          final inserted = await _syncSource(source);
          newArticles += inserted;
          await AppLogService.instance.info(
            'Finished refreshing source #${source.id}: '
            '$inserted new articles',
          );
        } catch (e) {
          errors.add('${source.title}: $e');
          await AppLogService.instance.error(
            'Refresh failed for source #${source.id} ${source.title}: $e',
          );
        }
      }
      progress.add(const SyncProgress('Downloading articles…'));
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
    }
  }

  Future<int> _syncRss(Source source) async {
    await AppLogService.instance.info(
      'Loading RSS feed #${source.id}: ${source.url}',
    );
    final response = await http
        .get(Uri.parse(source.url), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 25));
    await AppLogService.instance.info(
      'Loaded RSS feed #${source.id}: HTTP ${response.statusCode}, '
      '${response.body.length} bytes',
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final feed = FeedParser.parse(response.body);
    await AppLogService.instance.info(
      'Parsed RSS feed #${source.id}: "${feed.title}", '
      '${feed.items.length} item${feed.items.length == 1 ? '' : 's'}',
    );
    if (source.title.isEmpty || source.title == source.url) {
      await _db.updateSourceTitle(source.id!, feed.title);
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
      var markdown =
          hasFullContent
              ? ArticleExtractor.convertHtmlToMarkdown(item.contentHtml!)
              : null;
      if (markdown != null) {
        markdown = await _images.localizeMarkdown(
          markdown,
          maxDimension: _maxImageDimension,
        );
      }
      final isNew = await _db.insertArticleIfNew(
        Article(
          sourceId: source.id!,
          guid: item.guid,
          title: item.title,
          author: item.author,
          url: item.link,
          publishedAt: item.published?.millisecondsSinceEpoch,
          summary: _plainSummary(item.summaryHtml),
          contentMarkdown: markdown,
          fetched: (hasFullContent || item.link == null) ? 1 : 0,
          createdAt: now,
        ),
      );
      if (isNew) {
        inserted++;
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
      final isNew = await _db.insertArticleIfNew(
        Article(
          sourceId: source.id!,
          guid: tweet.id,
          title: _titleFromText(tweet.text),
          author: author,
          // Long-form posts keep the tweet permalink so the body stays;
          // others point at the linked article when there is one.
          url: tweet.isLongForm
              ? tweet.tweetUrl
              : (tweet.articleUrl ?? tweet.tweetUrl),
          publishedAt: tweet.createdAt?.millisecondsSinceEpoch,
          summary: tweet.text,
          contentMarkdown: downloadsArticle ? null : tweet.text,
          fetched: downloadsArticle ? 0 : 1,
          createdAt: now,
        ),
      );
      if (isNew) inserted++;
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
      progress.add(
        SyncProgress('Downloading articles… ${i + 1}/${pending.length}'),
      );
      await _fetchArticleContent(article);
    }
  }

  Future<void> _fetchArticleContent(Article article) async {
    final url = article.url;
    if (url == null) {
      await AppLogService.instance.debug(
        'Skipping article #${article.id} content fetch: no URL',
      );
      await _db.markArticleFetched(article.id!);
      return;
    }
    String body;
    try {
      await AppLogService.instance.debug(
        'Loading article #${article.id}: ${article.title} <$url>',
      );
      final response = await http
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
      return;
    }
    try {
      final markdown = ArticleExtractor.extract(body, baseUrl: url);
      if (markdown != null) {
        // Pull images onto the device so the article reads fully offline.
        final localized = await _images.localizeMarkdown(
          markdown,
          maxDimension: _maxImageDimension,
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
        // Tweets/notes get a placeholder title cut from their text; replace
        // it with the real page title once we have it.
        if (article.title.endsWith('…') || article.title == article.url) {
          final pageTitle = ArticleExtractor.extractTitle(body);
          if (pageTitle != null) {
            await _db.updateArticleTitle(article.id!, pageTitle);
          }
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
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= 90) return clean.isEmpty ? 'Untitled' : clean;
    final cut = clean.substring(0, 90);
    final lastSpace = cut.lastIndexOf(' ');
    return '${cut.substring(0, lastSpace > 40 ? lastSpace : 90)}…';
  }
}
