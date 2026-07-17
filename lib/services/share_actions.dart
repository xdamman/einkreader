import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
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

  /// One or many highlights with a single attribution:
  ///   "passage" — Title (url)
  /// or
  ///   My highlights from Title (url): "h1" "h2" …
  /// [withAttribution] is off when the destination already shows the source
  /// (a native quote tweet embeds the original).
  static String highlightsBody(Article article, List<Highlight> highlights,
      {bool withAttribution = true}) {
    final quotes = highlights.map((h) => '"${h.text}"').join('\n\n');
    if (!withAttribution) return quotes;
    if (highlights.length == 1) {
      return '$quotes\n\n— ${attribution(article)}';
    }
    return 'My highlights from ${attribution(article)}:\n\n$quotes';
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

  /// Edit-then-post tweet dialog. Shows which account will post (so there's
  /// no doubt which connection is active), adapts the character budget to
  /// the account's plan (see TwitterService.tweetMaxLength), and posts as a
  /// native quote tweet when [quoteTweetId] is given.
  static Future<void> onTwitter(BuildContext context,
      {required String draft, String? quoteTweetId}) async {
    final twitter = SyncService.instance.twitter;
    final maxLength = await twitter.tweetMaxLength();
    String? username;
    try {
      username = await twitter.username;
    } catch (_) {
      // Secure storage unavailable; just omit the byline.
    }
    if (!context.mounted) return;
    final controller = TextEditingController(
        text: draft.length > maxLength
            ? draft.substring(0, maxLength)
            : draft);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Share on Twitter'),
        content: Column(
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
              maxLength: maxLength,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText:
                    quoteTweetId != null ? 'Add your comment…' : null,
              ),
            ),
          ],
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
    if (text == null || text.isEmpty || !context.mounted) return;
    String message = 'Posted to Twitter';
    try {
      await twitter.postTweet(text, quoteTweetId: quoteTweetId);
    } catch (e) {
      message = 'Couldn\'t post: $e';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
