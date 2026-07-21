import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import 'outbox_service.dart';
import 'sync_service.dart';
import 'twitter_service.dart';

/// Share actions used by the reader's share menu, the in-article highlight
/// menu and the Highlights tab: prefilled email, an editable tweet sized to
/// the account's limit, and the canonical formatting for shared highlights.
class ShareActions {
  ShareActions._();

  /// True when a Twitter account is connected (false when secure storage is
  /// unavailable, e.g. in tests).
  static Future<bool> twitterConnected() async {
    try {
      return await SyncService.instance.twitter.isConnected;
    } catch (_) {
      return false;
    }
  }

  /// "Title (url)" — how the shared article is attributed, exactly once.
  static String attribution(Article article) => article.url == null
      ? article.displayTitle
      : '${article.displayTitle} (${article.url})';

  /// [highlights] reordered as they appear in the article text (unlocatable
  /// ones keep their relative order, after the located ones). The highlights
  /// list is stored newest-first, which reads backwards when quoting.
  static List<Highlight> inReadingOrder(
      Article article, List<Highlight> highlights) {
    final content = article.contentMarkdown ?? '';
    int positionOf(Highlight h) {
      final needle = h.text
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.length > 2, orElse: () => h.text.trim());
      final at = content.indexOf(needle);
      return at == -1 ? 1 << 30 : at;
    }

    // Decorate with the original index for a stable sort.
    final decorated = [
      for (var i = 0; i < highlights.length; i++)
        (position: positionOf(highlights[i]), index: i)
    ]..sort((a, b) {
        final byPosition = a.position.compareTo(b.position);
        return byPosition != 0 ? byPosition : a.index.compareTo(b.index);
      });
    return [for (final d in decorated) highlights[d.index]];
  }

  /// One or many highlights with a single attribution:
  ///   "passage" — Title (url)
  /// or
  ///   My highlights from Title (url): "h1" "h2" …
  /// in the order they appear in the article. [withAttribution] is off when
  /// the destination already shows the source (a native quote tweet embeds
  /// the original).
  static String highlightsBody(Article article, List<Highlight> highlights,
      {bool withAttribution = true}) {
    final quotes = inReadingOrder(article, highlights)
        .map((h) => '"${h.text}"')
        .join('\n\n');
    if (!withAttribution) return quotes;
    if (highlights.length == 1) {
      return '$quotes\n\n— ${attribution(article)}';
    }
    return 'My highlights from ${attribution(article)}:\n\n$quotes';
  }

  /// Preview card content for a quoted tweet, from the article's own stored
  /// text (works offline; the tweet IS the article).
  static ({String? author, String text}) _quotePreviewOf(Article article) {
    final raw =
        article.contentMarkdown ?? article.summary ?? article.displayTitle;
    final plain = Article.plainTitle(raw);
    return (
      author: article.author,
      text: plain.length > 280 ? '${plain.substring(0, 280)}…' : plain,
    );
  }

  /// Tweets the article: a native quote tweet when the article itself is a
  /// tweet (the comment starts empty), otherwise title + link.
  static Future<void> tweetArticle(BuildContext context, Article article) {
    final quoteTweetId = TwitterService.tweetIdFromUrl(article.url);
    return onTwitter(
      context,
      draft: quoteTweetId != null
          ? ''
          : [
              article.displayTitle,
              if (article.url != null) article.url!,
            ].join('\n'),
      quoteTweetId: quoteTweetId,
      quotePreview: quoteTweetId == null ? null : _quotePreviewOf(article),
    );
  }

  /// Tweets highlights; quoting the original tweet natively when the article
  /// is one (no textual attribution needed — the quote embeds it).
  static Future<void> tweetHighlights(
      BuildContext context, Article article, List<Highlight> highlights) {
    final quoteTweetId = TwitterService.tweetIdFromUrl(article.url);
    return onTwitter(
      context,
      draft: highlightsBody(article, highlights,
          withAttribution: quoteTweetId == null),
      quoteTweetId: quoteTweetId,
      quotePreview: quoteTweetId == null ? null : _quotePreviewOf(article),
    );
  }

  static String highlightsSubject(Article article, int count) =>
      'Highlight${count == 1 ? '' : 's'} from "${article.displayTitle}"';

  /// Opens the mail app pre-filled; falls back to the system share sheet
  /// when no mail app answers the mailto: intent.
  static Future<void> byEmail(BuildContext context,
      {required String subject, required String body}) async {
    final uri = Uri.parse('mailto:?subject=${Uri.encodeComponent(subject)}'
        '&body=${Uri.encodeComponent(body)}');
    try {
      if (await launchUrl(uri)) return;
    } catch (_) {
      // Fall through to the generic share sheet.
    }
    await Share.share(body, subject: subject);
  }

  /// Account facts the tweet dialog adapts to, resolved while it is already
  /// on screen (never blocks it): who posts, and their character budget.
  static Future<({int maxLength, String? username})> _accountInfo(
      TwitterService twitter) async {
    var maxLength = 280;
    String? username;
    try {
      maxLength = await twitter.tweetMaxLength();
    } catch (_) {}
    try {
      username = await twitter.username;
    } catch (_) {}
    return (maxLength: maxLength, username: username);
  }

  /// Edit-then-post tweet dialog. Shows which account will post (so there's
  /// no doubt which connection is active), adapts the character budget to
  /// the account's plan (see TwitterService.tweetMaxLength), and posts as a
  /// native quote tweet when [quoteTweetId] is given — with a preview card
  /// of the quoted post, like on twitter.com.
  static Future<void> onTwitter(BuildContext context,
      {required String draft,
      String? quoteTweetId,
      ({String? author, String text})? quotePreview}) async {
    final twitter = SyncService.instance.twitter;
    final accountInfo = _accountInfo(twitter);
    final controller = TextEditingController(text: draft);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Share on Twitter'),
        content: FutureBuilder(
          future: accountInfo,
          builder: (context, snapshot) {
            final username = snapshot.data?.username;
            return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (username != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Posting as @$username'
                  '${quoteTweetId != null ? ' · quoting the original post' : ''}',
                  style: const TextStyle(
                      fontSize: 13, fontStyle: FontStyle.italic),
                ),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 8,
              minLines: 3,
              maxLength: snapshot.data?.maxLength ?? 280,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText:
                    quoteTweetId != null ? 'Add your comment…' : null,
              ),
            ),
            // Rendered like a quote card on twitter.com: rounded bordered
            // box, author on top, tweet text below the comment field.
            if (quotePreview != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(width: 1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quotePreview.author != null &&
                        quotePreview.author!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          quotePreview.author!,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    Text(
                      quotePreview.text,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ],
                ),
              ),
          ],
            );
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Post')),
        ],
      ),
    );
    if (text == null || !context.mounted) return;
    if (text.isEmpty) {
      // Never drop silently — an empty post must say why nothing happened.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing posted — the tweet was empty')));
      return;
    }
    String message = 'Posted to Twitter';
    try {
      await twitter.postTweet(text, quoteTweetId: quoteTweetId);
    } catch (e) {
      // Keep the tweet: it lands in the outbox (icon on the home screen)
      // and is retried on the next sync or manually.
      await OutboxService.instance
          .enqueueTweet(text, quoteTweetId: quoteTweetId, error: '$e');
      message = 'Couldn\'t post now — kept in the outbox for retry';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
