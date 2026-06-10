import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'extractor.dart';
import 'feed_parser.dart';
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

  final progress =
      StreamController<SyncProgress>.broadcast(sync: true);
  bool _syncing = false;
  bool get isSyncing => _syncing;

  static const _userAgent =
      'Mozilla/5.0 (compatible; einkreader/0.1; +https://github.com/xdamman/einkreader)';

  /// Updates all sources, then fetches missing article content.
  /// Returns a human-readable summary.
  Future<String> syncAll() async {
    if (_syncing) return 'Sync already running';
    _syncing = true;
    var newArticles = 0;
    final errors = <String>[];
    try {
      final sources = await _db.getSources();
      for (final source in sources) {
        progress.add(SyncProgress('Updating ${source.title}…'));
        try {
          newArticles += await _syncSource(source);
        } catch (e) {
          errors.add('${source.title}: $e');
        }
      }
      progress.add(const SyncProgress('Downloading articles…'));
      await _fetchPendingContent();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'last_sync', DateTime.now().millisecondsSinceEpoch);
    } finally {
      _syncing = false;
      progress.add(const SyncProgress('', running: false));
    }
    final summary = newArticles == 0
        ? 'Up to date'
        : '$newArticles new article${newArticles == 1 ? '' : 's'}';
    return errors.isEmpty ? summary : '$summary · ${errors.first}';
  }

  Future<int> _syncSource(Source source) async {
    switch (source.type) {
      case SourceType.rss:
        return _syncRss(source);
      case SourceType.twitterBookmarks:
        return _insertTweets(source, await twitter.fetchBookmarks());
      case SourceType.twitterLikes:
        return _insertTweets(source, await twitter.fetchLikes());
      case SourceType.nostrBookmarks:
        return _insertNostrItems(
            source, await nostr.fetchBookmarks(source.url));
      case SourceType.nostrLikes:
        return _insertNostrItems(source, await nostr.fetchLikes(source.url));
    }
  }

  Future<int> _syncRss(Source source) async {
    final response = await http.get(Uri.parse(source.url),
        headers: {'User-Agent': _userAgent}).timeout(
        const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final feed = FeedParser.parse(response.body);
    if (source.title.isEmpty || source.title == source.url) {
      await _db.updateSourceTitle(source.id!, feed.title);
    }
    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in feed.items) {
      // Feeds that ship full content need no page download.
      final hasFullContent = (item.contentHtml ?? '').length > 600;
      final markdown = hasFullContent
          ? ArticleExtractor.convertHtmlToMarkdown(item.contentHtml!)
          : null;
      final isNew = await _db.insertArticleIfNew(Article(
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
      ));
      if (isNew) inserted++;
    }
    return inserted;
  }

  Future<int> _insertTweets(Source source, List<TweetItem> tweets) async {
    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final tweet in tweets) {
      final author = tweet.authorName ??
          (tweet.authorUsername != null ? '@${tweet.authorUsername}' : null);
      final isNew = await _db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: tweet.id,
        title: _titleFromText(tweet.text),
        author: author,
        url: tweet.articleUrl ?? tweet.tweetUrl,
        publishedAt: tweet.createdAt?.millisecondsSinceEpoch,
        summary: tweet.text,
        contentMarkdown: tweet.articleUrl == null ? tweet.text : null,
        // Only linked external articles need a content download.
        fetched: tweet.articleUrl == null ? 1 : 0,
        createdAt: now,
      ));
      if (isNew) inserted++;
    }
    return inserted;
  }

  Future<int> _insertNostrItems(Source source, List<NostrItem> items) async {
    var inserted = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      final isUrlOnly = item.content == item.articleUrl;
      final isNew = await _db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: item.id,
        title: _titleFromText(
            isUrlOnly ? (item.articleUrl ?? item.content) : item.content),
        author: item.authorPubkey != null
            ? 'nostr:${item.authorPubkey!.substring(0, 12)}…'
            : null,
        url: item.articleUrl,
        publishedAt: item.createdAt?.millisecondsSinceEpoch,
        summary: item.content,
        contentMarkdown: item.articleUrl == null ? item.content : null,
        fetched: item.articleUrl == null ? 1 : 0,
        createdAt: now,
      ));
      if (isNew) inserted++;
    }
    return inserted;
  }

  /// Downloads and extracts content for all articles still missing it.
  Future<void> _fetchPendingContent() async {
    final pending = await _db.getUnfetchedArticles();
    for (var i = 0; i < pending.length; i++) {
      final article = pending[i];
      progress.add(SyncProgress(
          'Downloading articles… ${i + 1}/${pending.length}'));
      await _fetchArticleContent(article);
    }
  }

  Future<void> _fetchArticleContent(Article article) async {
    final url = article.url;
    if (url == null) {
      await _db.markArticleFetched(article.id!);
      return;
    }
    String body;
    try {
      final response = await http.get(Uri.parse(url),
          headers: {'User-Agent': _userAgent}).timeout(
          const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      body = response.body;
    } catch (_) {
      // Network failure: keep fetched = 0 so the next sync retries.
      return;
    }
    try {
      final markdown = ArticleExtractor.extract(body, baseUrl: url);
      if (markdown != null) {
        var content = markdown;
        // Keep the original note/tweet above the extracted article.
        if (article.summary != null &&
            article.contentMarkdown == null &&
            article.summary != article.title) {
          final intro = _plainSummary(article.summary)!;
          if (!_looksLikeHtml(article.summary!) && intro.length < 600) {
            content = '> $intro\n\n---\n\n$markdown';
          }
        }
        await _db.updateArticleContent(article.id!, content, fetched: true);
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
        final fallback = _plainSummary(article.summary) ??
            'Could not extract this page. Open it in the browser instead.';
        await _db.updateArticleContent(article.id!, fallback, fetched: true);
      }
    } catch (_) {
      await _db.markArticleFetched(article.id!);
    }
  }

  static bool _looksLikeHtml(String text) => text.contains(RegExp(r'<[a-z]+'));

  static String? _plainSummary(String? html) {
    if (html == null) return null;
    final text = html
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
