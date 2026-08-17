import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/profile_screen.dart';
import '../services/errors.dart';
import '../services/outbox_service.dart';
import '../services/profile_service.dart';
import '../services/share_actions.dart';
import '../services/sync_service.dart';
import '../services/twitter_service.dart';

/// Note-taking and sharing merged into one overlay: the quote, a roomy note
/// field, the share channels, and the immediate hand-offs — the only
/// difference between "Add note" and "Share…" is what's checked by default
/// (a note stays private unless a channel is picked). An overlay rather
/// than a full screen on purpose: the article stays visible behind it.
///
/// With several highlights ([ShareNoteDialog.openAll]) the same overlay
/// shares them combined: one tweet / email with every quote, each published
/// to the profile. The note field is hidden — notes belong to a single
/// highlight.
class ShareNoteDialog extends StatefulWidget {
  final Article article;

  /// The highlights being shared, in reading order. A single entry is the
  /// classic note/share flow; several entries share them combined.
  final List<Highlight> highlights;

  /// True when entered via "Share…": the profile channel starts checked.
  /// Via "Add note" nothing is checked — saving keeps the note private.
  final bool shareByDefault;

  const ShareNoteDialog({
    super.key,
    required this.article,
    required this.highlights,
    required this.shareByDefault,
  }) : assert(highlights.length > 0);

  static Future<void> open(BuildContext context,
      {required Article article,
      required Highlight highlight,
      required bool shareByDefault}) =>
      showDialog(
        context: context,
        builder: (_) => ShareNoteDialog(
            article: article,
            highlights: [highlight],
            shareByDefault: shareByDefault),
      );

  /// Shares all of an article's [highlights] combined (always share mode).
  static Future<void> openAll(BuildContext context,
      {required Article article, required List<Highlight> highlights}) =>
      showDialog(
        context: context,
        builder: (_) => ShareNoteDialog(
            article: article, highlights: highlights, shareByDefault: true),
      );

  @override
  State<ShareNoteDialog> createState() => _ShareNoteDialogState();
}

class _ShareNoteDialogState extends State<ShareNoteDialog> {
  final _db = AppDatabase.instance;
  late final TextEditingController _comment =
      TextEditingController(text: _single?.comment ?? '');

  bool _loaded = false;
  bool _hasProfile = false;
  bool _twitterConnected = false;

  bool _toProfile = false;
  bool _toTwitter = false;
  bool _sharing = false;

  /// The one highlight of the classic flow; null when sharing several.
  Highlight? get _single =>
      widget.highlights.length == 1 ? widget.highlights.first : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final hasProfile = await ProfileService.instance.enabled;
    final twitterConnected = await ShareActions.twitterConnected();
    if (!mounted) return;
    setState(() {
      _hasProfile = hasProfile;
      _twitterConnected = twitterConnected;
      _toProfile = widget.shareByDefault && hasProfile;
      _loaded = true;
    });
  }

  bool get _anyChannel =>
      (_toProfile && _hasProfile) || (_toTwitter && _twitterConnected);

  /// The single highlight with the dialog's note attached (multi-share
  /// leaves comments untouched — notes belong to one highlight).
  Future<List<Highlight>> _withComment() async {
    final single = _single;
    if (single == null) return widget.highlights;
    final comment = _comment.text.trim();
    if (comment != (single.comment ?? '')) {
      await _db.updateHighlightComment(
          single.id!, comment.isEmpty ? null : comment);
    }
    return [
      Highlight(
        id: single.id,
        articleId: single.articleId,
        text: single.text,
        comment: comment.isEmpty ? null : comment,
        shared: _anyChannel ? 1 : single.shared,
        createdAt: single.createdAt,
      )
    ];
  }

  Future<void> _record(String medium, Highlight highlight,
      {String? recipient, String? ref}) async {
    await _db.insertShare(Share(
      highlightId: highlight.id!,
      medium: medium,
      recipient: recipient,
      ref: ref,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Ensures a highlight is published to the profile; returns the event id
  /// (existing or fresh).
  Future<String> _ensurePublished(Highlight highlight) async {
    final existing = await _db.profileShareRef(highlight.id!);
    if (existing != null) return existing;
    final result = await ProfileService.instance
        .publishHighlight(widget.article, highlight);
    return result.eventId;
  }

  /// Copy link is immediate — publishes to the profile if needed so the
  /// link resolves, then copies. Without a profile (or with several
  /// highlights) the article URL is copied instead.
  Future<void> _copyLink() async {
    final single = _single;
    if (!_hasProfile || single == null) {
      final url = widget.article.url;
      if (url == null) return;
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Article link copied')));
      return;
    }
    final highlight = (await _withComment()).first;
    final eventId = await _ensurePublished(highlight);
    final link = await ProfileService.instance.quoteLink(eventId);
    if (link == null) return;
    await _record('link', highlight, ref: eventId);
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Link copied: $link')));
  }

  /// Opens the mail app pre-filled — an immediate hand-off, not a channel.
  Future<void> _composeEmail() async {
    final highlights = await _withComment();
    if (!mounted) return;
    await ShareActions.byEmail(
      context,
      subject:
          ShareActions.highlightsSubject(widget.article, highlights.length),
      body: ShareActions.highlightsBody(widget.article, highlights),
    );
    for (final highlight in highlights) {
      await _record('email', highlight);
    }
  }

  /// Save (private note only) or Share (checked channels). Sharing is
  /// instant for the user: the note is persisted, the dialog closes right
  /// away, and the actual publishing runs in the background — offline or
  /// slow networks never block, anything unsendable waits in the outbox.
  Future<void> _save() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final highlights = await _withComment();
    final toProfile = _toProfile && _hasProfile;
    final toTwitter = _toTwitter && _twitterConnected;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    if (!toProfile && !toTwitter) {
      messenger.showSnackBar(const SnackBar(content: Text('Note saved')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Sharing…')));
    unawaited(_shareInBackground(
      highlights: highlights,
      toProfile: toProfile,
      toTwitter: toTwitter,
      messenger: messenger,
    ));
  }

  /// The slow part of sharing, detached from the (already closed) dialog.
  /// Touches no widget state — only services, the db and the app-level
  /// messenger it was handed.
  Future<void> _shareInBackground({
    required List<Highlight> highlights,
    required bool toProfile,
    required bool toTwitter,
    required ScaffoldMessengerState messenger,
  }) async {
    final article = widget.article;
    final done = <String>[];
    final failed = <String>[];

    if (toProfile) {
      try {
        var accepted = 0;
        var published = 0;
        for (final highlight in highlights) {
          // A single share always (re)publishes — the note may have changed.
          // A combined share skips quotes already on the profile.
          if (_single == null &&
              await _db.profileShareRef(highlight.id!) != null) {
            continue;
          }
          final result = await ProfileService.instance
              .publishHighlight(article, highlight);
          await _record('profile', highlight, ref: result.eventId);
          published++;
          accepted += result.accepted;
        }
        done.add(
            published > 0 && accepted == 0 ? 'profile (queued)' : 'profile');
      } catch (e) {
        failed.add(friendlyError(e, doing: 'publishing to your profile'));
      }
    }

    if (toTwitter) {
      final quoteId = TwitterService.tweetIdFromUrl(article.url);
      final text = ShareActions.highlightsBody(article, highlights,
          withAttribution: quoteId == null);
      try {
        await SyncService.instance.twitter
            .postTweet(text, quoteTweetId: quoteId);
        for (final highlight in highlights) {
          await _record('twitter', highlight);
        }
        done.add('twitter');
      } catch (e) {
        await OutboxService.instance
            .enqueueTweet(text, quoteTweetId: quoteId, error: '$e');
        for (final highlight in highlights) {
          await _record('twitter', highlight);
        }
        done.add('twitter (queued)');
      }
    }

    // Report the outcome via the app-level messenger — the dialog is long
    // gone. "queued" entries go out with the outbox on the next sync.
    final message = failed.isEmpty
        ? 'Shared: ${done.join(', ')}'
        : done.isEmpty
            ? failed.join('; ')
            : 'Shared: ${done.join(', ')} — failed: ${failed.join('; ')}';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required IconData trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 10),
            Expanded(
                child: Text(label, style: const TextStyle(fontSize: 15))),
            Icon(trailing, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _checkRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String label,
    String? trailing,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              value && enabled
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              size: 22,
              color: enabled ? Colors.black : Colors.grey,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 15,
                      color: enabled ? Colors.black : Colors.grey)),
            ),
            if (trailing != null)
              Text(trailing,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final single = _single;
    return Dialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The quote(s) this note/share is about.
              Container(
                padding: const EdgeInsets.only(left: 12),
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(width: 3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        widget.highlights
                            .map((h) => h.text)
                            .join('\n\n'),
                        maxLines: single == null ? 8 : 5,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, height: 1.4)),
                    const SizedBox(height: 4),
                    Text(
                        single == null
                            ? '${widget.highlights.length} highlights · '
                                '${widget.article.displayTitle}'
                            : widget.article.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Roomy on purpose: notes are written here, not in a slit.
              // Only for a single highlight — a note belongs to one quote.
              if (single != null) ...[
                TextField(
                  controller: _comment,
                  autofocus: !widget.shareByDefault,
                  minLines: 6,
                  maxLines: 14,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                  decoration: const InputDecoration(
                    labelText: 'Your note (optional)',
                    helperText: 'Stays private unless you share it',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (_hasProfile)
                _checkRow(
                  value: _toProfile,
                  onChanged: (v) => setState(() => _toProfile = v),
                  label: 'Your profile',
                  trailing: 'einkreader.app',
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border:
                        Border.all(width: 1.5, style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Create your public profile',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const Text(
                          'A page people can follow — your highlights and '
                          'comments at einkreader.app/you. Free.',
                          style: TextStyle(fontSize: 12.5)),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: () async {
                          await Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const ProfileScreen()));
                          _load();
                        },
                        child: const Text('Create profile'),
                      ),
                    ],
                  ),
                ),
              _checkRow(
                value: _toTwitter,
                onChanged: (v) => setState(() => _toTwitter = v),
                label: 'Tweet it',
                enabled: _twitterConnected,
                trailing: _twitterConnected
                    ? (TwitterService.tweetIdFromUrl(widget.article.url) !=
                            null
                        ? 'quote-tweet'
                        : null)
                    : 'connect Twitter in Settings',
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _sharing ? null : _save,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  side: const BorderSide(width: 2),
                ),
                child: Text(
                    _sharing
                        ? 'Sharing…'
                        : (_anyChannel ? 'Share' : 'Save'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              // Not channels — immediate hand-offs, below the button.
              const Divider(height: 28),
              _actionRow(
                icon: Icons.link,
                label: _hasProfile && single != null
                    ? 'Copy link to this quote'
                    : 'Copy article link',
                trailing: Icons.copy,
                onTap: _copyLink,
              ),
              _actionRow(
                icon: Icons.email_outlined,
                label: 'Compose an email…',
                trailing: Icons.open_in_new,
                onTap: _composeEmail,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
