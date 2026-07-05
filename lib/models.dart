/// Data models for sources, articles and highlights.
library;

enum SourceType {
  rss,
  twitterBookmarks,
  twitterLikes,
  nostrBookmarks,
  nostrLikes,

  /// Built-in queue of links the user saved from inside articles. Nothing to
  /// pull remotely — its articles are inserted locally with fetched = 0 and
  /// downloaded by the regular pending-content pass.
  savedLinks;

  static SourceType fromName(String name) =>
      SourceType.values.firstWhere((t) => t.name == name,
          orElse: () => SourceType.rss);

  String get label => switch (this) {
        SourceType.rss => 'RSS',
        SourceType.twitterBookmarks => 'Twitter Bookmarks',
        SourceType.twitterLikes => 'Twitter Likes',
        SourceType.nostrBookmarks => 'Nostr Bookmarks',
        SourceType.nostrLikes => 'Nostr Likes',
        SourceType.savedLinks => 'Saved Links',
      };
}

class Source {
  final int? id;
  final SourceType type;
  final String title;

  /// RSS: feed URL. Nostr: npub. Twitter: username (informational).
  final String url;
  final int createdAt;

  const Source({
    this.id,
    required this.type,
    required this.title,
    required this.url,
    required this.createdAt,
  });

  Source copyWith({int? id, String? title}) => Source(
        id: id ?? this.id,
        type: type,
        title: title ?? this.title,
        url: url,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'type': type.name,
        'title': title,
        'url': url,
        'created_at': createdAt,
      };

  static Source fromMap(Map<String, Object?> m) => Source(
        id: m['id'] as int?,
        type: SourceType.fromName(m['type'] as String),
        title: m['title'] as String,
        url: m['url'] as String,
        createdAt: m['created_at'] as int,
      );
}

class Article {
  final int? id;
  final int sourceId;

  /// Stable identifier within the source (rss guid, tweet id, nostr event id).
  final String guid;
  final String title;
  final String? author;
  final String? url;
  final int? publishedAt;
  final String? summary;

  /// Full article content as Markdown, ready for offline reading.
  final String? contentMarkdown;

  /// 0 = content still needs to be fetched, 1 = content is final.
  final int fetched;
  final int read;
  final int readLater;
  final int favorite;
  final int createdAt;

  /// Saved reading position in scroll pixels. An unread article with a
  /// position > 0 is "being read" and shows up under Resume reading; reaching
  /// the bottom marks it read and clears the position.
  final double scrollPosition;

  /// When [scrollPosition] was last saved, so Resume reading can order by
  /// most recently touched. Null when there is no saved position.
  final int? scrolledAt;

  /// For links saved from inside another article: the id of the article the
  /// link was found in, shown as "From: …" in the reader header.
  final int? viaArticleId;

  const Article({
    this.id,
    required this.sourceId,
    required this.guid,
    required this.title,
    this.author,
    this.url,
    this.publishedAt,
    this.summary,
    this.contentMarkdown,
    this.fetched = 0,
    this.read = 0,
    this.readLater = 0,
    this.favorite = 0,
    required this.createdAt,
    this.scrollPosition = 0,
    this.scrolledAt,
    this.viaArticleId,
  });

  Article copyWith({String? title, String? contentMarkdown, int? favorite}) =>
      Article(
        id: id,
        sourceId: sourceId,
        guid: guid,
        title: title ?? this.title,
        author: author,
        url: url,
        publishedAt: publishedAt,
        summary: summary,
        contentMarkdown: contentMarkdown ?? this.contentMarkdown,
        fetched: fetched,
        read: read,
        readLater: readLater,
        favorite: favorite ?? this.favorite,
        createdAt: createdAt,
        scrollPosition: scrollPosition,
        scrolledAt: scrolledAt,
        viaArticleId: viaArticleId,
      );

  /// Normalized form of [url] used to detect the same story arriving from
  /// different sources (e.g. an RSS item and a tweet linking to it). Null when
  /// there is no URL to compare.
  String? get urlKey => canonicalUrl(url);

  /// [title] with Markdown syntax and bare URLs removed, for plain-text display
  /// in the feed. Titles are derived from RSS/tweet/note bodies, so they may
  /// carry links, emphasis markers, heading/quote markers or raw URLs.
  String get displayTitle => plainTitle(title);

  /// Strips Markdown markup and bare URLs from [raw], collapsing the leftover
  /// whitespace. Falls back to the trimmed original if nothing readable remains
  /// (e.g. a title that was only a link).
  static String plainTitle(String raw) {
    var text = raw
        // [text](url) and ![alt](url) -> just the visible text / alt.
        .replaceAllMapped(
            RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
        // Bare URLs.
        .replaceAll(RegExp(r'https?://\S+'), '')
        // Leading heading (#) and blockquote (>) markers.
        .replaceAll(RegExp(r'^\s*#{1,6}\s+'), '')
        .replaceAll(RegExp(r'^\s*>\s?'), '')
        // Emphasis / inline-code markers.
        .replaceAll(RegExp(r'\*+|~~|`'), '')
        // Collapse whitespace left behind by the removals.
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.isEmpty ? raw.trim() : text;
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'source_id': sourceId,
        'guid': guid,
        'title': title,
        'author': author,
        'url': url,
        'url_key': urlKey,
        'published_at': publishedAt,
        'summary': summary,
        'content_markdown': contentMarkdown,
        'fetched': fetched,
        'read': read,
        'read_later': readLater,
        'favorite': favorite,
        'created_at': createdAt,
        'scroll_position': scrollPosition,
        'scrolled_at': scrolledAt,
        'via_article_id': viaArticleId,
      };

  /// Canonicalizes a URL for deduplication: lowercases the host, drops
  /// `www.`, the scheme, the fragment, common tracking query parameters and
  /// any trailing slash. Returns null for empty/invalid input.
  static String? canonicalUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return null;
    var host = uri.host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    final params = Map<String, String>.fromEntries(
      uri.queryParameters.entries.where((e) {
        final k = e.key.toLowerCase();
        return !k.startsWith('utm_') &&
            k != 'fbclid' &&
            k != 'gclid' &&
            k != 'igshid' &&
            k != 'ref' &&
            k != 'ref_src' &&
            k != 's' &&
            k != 'cmpid';
      }),
    );
    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final query = params.isEmpty
        ? ''
        : '?${(params.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';
    return '$host$path$query';
  }

  static Article fromMap(Map<String, Object?> m) => Article(
        id: m['id'] as int?,
        sourceId: m['source_id'] as int,
        guid: m['guid'] as String,
        title: m['title'] as String,
        author: m['author'] as String?,
        url: m['url'] as String?,
        publishedAt: m['published_at'] as int?,
        summary: m['summary'] as String?,
        contentMarkdown: m['content_markdown'] as String?,
        fetched: (m['fetched'] as int?) ?? 0,
        read: (m['read'] as int?) ?? 0,
        readLater: (m['read_later'] as int?) ?? 0,
        favorite: (m['favorite'] as int?) ?? 0,
        createdAt: m['created_at'] as int,
        scrollPosition: (m['scroll_position'] as num?)?.toDouble() ?? 0,
        scrolledAt: m['scrolled_at'] as int?,
        viaArticleId: m['via_article_id'] as int?,
      );
}

class Highlight {
  final int? id;
  final int articleId;
  final String text;
  final int createdAt;

  /// Populated by joins for display purposes.
  final String? articleTitle;

  const Highlight({
    this.id,
    required this.articleId,
    required this.text,
    required this.createdAt,
    this.articleTitle,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'article_id': articleId,
        'text': text,
        'created_at': createdAt,
      };

  static Highlight fromMap(Map<String, Object?> m) => Highlight(
        id: m['id'] as int?,
        articleId: m['article_id'] as int,
        text: m['text'] as String,
        createdAt: m['created_at'] as int,
        articleTitle: m['article_title'] as String?,
      );
}
