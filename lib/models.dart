/// Data models for sources, articles and highlights.
library;

enum SourceType {
  rss,
  twitterBookmarks,
  twitterLikes,
  nostrBookmarks,
  nostrLikes;

  static SourceType fromName(String name) =>
      SourceType.values.firstWhere((t) => t.name == name,
          orElse: () => SourceType.rss);

  String get label => switch (this) {
        SourceType.rss => 'RSS',
        SourceType.twitterBookmarks => 'Twitter Bookmarks',
        SourceType.twitterLikes => 'Twitter Likes',
        SourceType.nostrBookmarks => 'Nostr Bookmarks',
        SourceType.nostrLikes => 'Nostr Likes',
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
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'source_id': sourceId,
        'guid': guid,
        'title': title,
        'author': author,
        'url': url,
        'published_at': publishedAt,
        'summary': summary,
        'content_markdown': contentMarkdown,
        'fetched': fetched,
        'read': read,
        'read_later': readLater,
        'favorite': favorite,
        'created_at': createdAt,
      };

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
