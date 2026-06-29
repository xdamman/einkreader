/// Pure (Flutter-free) helpers for turning X API v2 tweet/article JSON into
/// Markdown. Shared by the app's [TwitterService] and the `tweet_md` CLI so the
/// conversion can be iterated on and unit-tested without a device.
library;

/// Replaces t.co links in a tweet/note body with their expanded form. Works for
/// both a tweet object and a note_tweet object (both expose entities.urls).
String expandTweetUrls(Map<String, dynamic> body) {
  var text = body['text'] as String? ?? '';
  final urls = (body['entities']?['urls'] as List?) ?? const [];
  for (final u in urls) {
    final shortUrl = u['url'] as String?;
    final expanded = (u['expanded_url'] ?? u['unwound_url']) as String?;
    if (shortUrl != null && expanded != null) {
      text = text.replaceAll(shortUrl, expanded);
    }
  }
  return text;
}

/// First non-x.com / non-twitter.com URL in [body], used to fetch a linked
/// article downloaded from the open web.
String? firstExternalUrl(Map<String, dynamic> body) {
  final urls = (body['entities']?['urls'] as List?) ?? const [];
  for (final u in urls) {
    final expanded = (u['unwound_url'] ?? u['expanded_url']) as String?;
    if (expanded == null) continue;
    final host = Uri.tryParse(expanded)?.host ?? '';
    if (host.endsWith('twitter.com') || host.endsWith('x.com')) continue;
    return expanded;
  }
  return null;
}

/// Status id of another X post this tweet points at (a quote, or an
/// x.com/twitter.com status link in the text), used to inline a referenced
/// native article.
String? linkedTweetId(Map<String, dynamic> tweet, Map<String, dynamic> body) {
  final referenced = (tweet['referenced_tweets'] as List?) ?? const [];
  for (final r in referenced) {
    if (r['type'] == 'quoted' && r['id'] != null) return r['id'] as String;
  }
  final urls = (body['entities']?['urls'] as List?) ?? const [];
  for (final u in urls) {
    final expanded = (u['unwound_url'] ?? u['expanded_url']) as String?;
    final uri = expanded == null ? null : Uri.tryParse(expanded);
    if (uri == null) continue;
    if (!(uri.host.endsWith('twitter.com') || uri.host.endsWith('x.com'))) {
      continue;
    }
    final match = RegExp(r'/status/(\d+)').firstMatch(uri.path);
    if (match != null) return match.group(1);
  }
  return null;
}

/// The note_tweet ("longer tweet") body, when present.
Map<String, dynamic>? noteOf(Map<String, dynamic> tweet) {
  final note = tweet['note_tweet'] as Map<String, dynamic>?;
  return (note?['text'] as String?) != null ? note : null;
}

/// The X Article object, when this tweet is a native article with a body.
Map<String, dynamic>? articleOf(Map<String, dynamic> tweet) {
  final article = tweet['article'] as Map<String, dynamic>?;
  final body = (article?['plain_text'] as String?)?.trim() ?? '';
  return body.isEmpty ? null : article;
}

/// Whether a tweet carries a native long-form body (note_tweet or X Article).
bool isLongFormTweet(Map<String, dynamic> tweet) =>
    noteOf(tweet) != null || articleOf(tweet) != null;

/// Full Markdown body for a tweet: a note_tweet, an X Article, or the plain
/// tweet text. [mediaUrls] maps a media key to its image URL (cover/inline
/// images); [embeddedPosts] maps an embedded post's id to its rendered
/// Markdown (e.g. a blockquote).
String tweetBodyMarkdown(
  Map<String, dynamic> tweet, {
  Map<String, String> mediaUrls = const {},
  Map<String, String> embeddedPosts = const {},
}) {
  final note = noteOf(tweet);
  if (note != null) {
    return _withAttachedImages(expandTweetUrls(note), tweet, mediaUrls);
  }
  final article = articleOf(tweet);
  if (article != null) {
    return articleToMarkdown(article,
        mediaUrls: mediaUrls, embeddedPosts: embeddedPosts);
  }
  return _withAttachedImages(expandTweetUrls(tweet), tweet, mediaUrls);
}

/// Appends the tweet's attached photos as image Markdown (so they are
/// downloaded and shown rather than left as a link), removing the media-page
/// link the API leaves in the text.
String _withAttachedImages(
    String text, Map<String, dynamic> tweet, Map<String, String> mediaUrls) {
  final keys = (tweet['attachments']?['media_keys'] as List?) ?? const [];
  final images = keys
      .map((k) => mediaUrls[k as String?])
      .whereType<String>()
      .map((url) => '![]($url)')
      .toList();
  var body = text
      .replaceAll(RegExp(r'https?://\S*/(?:photo|video)/\d+\S*'), '')
      .trimRight();
  if (images.isEmpty) return body;
  final block = images.join('\n\n');
  return body.isEmpty ? block : '$body\n\n$block';
}

/// Converts an X Article object to Markdown: a heading, the cover image, the
/// body split into paragraphs (X Articles separate them with single newlines),
/// then any posts embedded in the article.
///
/// Rich inline formatting (bold/italic) and inline image/embed positions are
/// not exposed by the v2 `article` field — only `plain_text` plus entity lists
/// — so embeds are appended rather than interleaved. See the `tweet_md` CLI to
/// inspect the raw payload.
String articleToMarkdown(
  Map<String, dynamic> article, {
  Map<String, String> mediaUrls = const {},
  Map<String, String> embeddedPosts = const {},
}) {
  final out = <String>[];
  final title = (article['title'] as String?)?.trim() ?? '';
  if (title.isNotEmpty) out.add('# $title');

  final coverKey = article['cover_media'] as String?;
  final coverUrl = coverKey == null ? null : mediaUrls[coverKey];
  if (coverUrl != null) out.add('![]($coverUrl)');

  final body = (article['plain_text'] as String?) ?? '';
  for (final paragraph in body.split('\n')) {
    final trimmed = paragraph.trim();
    if (trimmed.isNotEmpty) out.add(_formatArticleParagraph(trimmed));
  }

  final embeds = (article['entities']?['tweets'] as List?) ?? const [];
  for (final embed in embeds) {
    final id = embed['id'] as String?;
    final markdown = id == null ? null : embeddedPosts[id];
    if (markdown != null) out.add('---\n\n$markdown');
  }
  return out.join('\n\n');
}

/// A short standalone line that reads like a section heading (no terminal
/// punctuation, few words).
final _headingLike = RegExp(r'^(?=.{1,64}$)(?!.*[.!?:,;]$)[A-Z].*$');

/// A bold "Term:" lead-in at the start of a list item / paragraph, e.g.
/// "Browser: …" — the term is short, capitalized and colon-terminated.
final _boldLeadIn = RegExp(r'^([A-Z][^:.!?,;\n]{0,29}):\s+(\S.*)$');

/// X Articles arrive as `plain_text` with all rich formatting stripped. This
/// restores the two structures that survive as text: short heading lines become
/// `##` headings, and "Term:" lead-ins are bolded. It is a heuristic — the v2
/// API exposes no formatting runs — so it stays conservative.
String _formatArticleParagraph(String text) {
  // A "Term:" lead-in wins over the heading rule so a short one is not mistaken
  // for a heading.
  final lead = _boldLeadIn.firstMatch(text);
  if (lead != null) return '**${lead.group(1)}:** ${lead.group(2)}';
  if (text.split(' ').length <= 8 && _headingLike.hasMatch(text)) {
    return '## $text';
  }
  return text;
}

/// Renders a post as a Markdown blockquote with attribution, for inlining an
/// embedded or quoted post inside another story.
String postBlockquote(String text, {String? authorName, String? authorUsername}) {
  final quoted = text
      .split('\n')
      .map((line) => line.trim().isEmpty ? '>' : '> $line')
      .join('\n');
  final who = authorName ?? (authorUsername != null ? '@$authorUsername' : null);
  return who == null ? quoted : '$quoted\n>\n> — $who';
}
