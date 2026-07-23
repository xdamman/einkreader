import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/outbox_service.dart';
import '../services/plugin_service.dart';
import '../services/profile_service.dart';
import '../services/share_actions.dart';
import '../services/sync_service.dart';
import '../services/twitter_service.dart';
import 'contacts_screen.dart';
import 'plugin_pitch_screen.dart';
import 'profile_screen.dart';

/// The share composer: one full-screen push with the quote, an optional
/// comment and every destination in one place. Free rows always work
/// (profile, compose-email, copy link); plugin rows are visible but locked
/// until the supporter subscription, tapping through to the pitch.
class ShareScreen extends StatefulWidget {
  final Article article;
  final Highlight highlight;

  const ShareScreen(
      {super.key, required this.article, required this.highlight});

  static Future<void> open(BuildContext context,
      {required Article article, required Highlight highlight}) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              ShareScreen(article: article, highlight: highlight)));

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final _db = AppDatabase.instance;
  late final TextEditingController _comment =
      TextEditingController(text: widget.highlight.comment ?? '');

  bool _loaded = false;
  bool _hasProfile = false;
  bool _twitterConnected = false;
  bool _supporter = false;
  bool _emailPluginOn = false;
  List<Contact> _contacts = [];

  bool _toProfile = false;
  bool _toTwitter = false;
  bool _toComposeEmail = false;
  final Set<int> _toContacts = {};
  bool _sharing = false;

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
    final supporter = await PluginService.instance.isSupporter;
    final emailOn = await PluginService.instance.emailActive;
    final contacts = await _db.getContacts();
    if (!mounted) return;
    setState(() {
      _hasProfile = hasProfile;
      _twitterConnected = twitterConnected;
      _supporter = supporter;
      _emailPluginOn = emailOn;
      _contacts = contacts;
      _toProfile = hasProfile;
      _loaded = true;
    });
  }

  bool get _twitterUsable => _supporter && _twitterConnected;

  /// The highlight with the composer's comment attached.
  Future<Highlight> _withComment() async {
    final comment = _comment.text.trim();
    if (comment != (widget.highlight.comment ?? '')) {
      await _db.updateHighlightComment(
          widget.highlight.id!, comment.isEmpty ? null : comment);
    }
    return Highlight(
      id: widget.highlight.id,
      articleId: widget.highlight.articleId,
      text: widget.highlight.text,
      comment: comment.isEmpty ? null : comment,
      shared: 1,
      createdAt: widget.highlight.createdAt,
    );
  }

  Future<void> _record(String medium,
      {String? recipient, String? ref}) async {
    await _db.insertShare(Share(
      highlightId: widget.highlight.id!,
      medium: medium,
      recipient: recipient,
      ref: ref,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Ensures the highlight is published to the profile; returns the event id
  /// (existing or fresh).
  Future<String> _ensurePublished(Highlight highlight) async {
    final existing = await _db.profileShareRef(widget.highlight.id!);
    if (existing != null) return existing;
    final result = await ProfileService.instance
        .publishHighlight(widget.article, highlight);
    return result.eventId;
  }

  /// Copy link is immediate — publishes to the profile if needed so the
  /// link resolves, then copies. Without a profile the article URL is
  /// copied instead (quote links require a profile).
  Future<void> _copyLink() async {
    if (!_hasProfile) {
      final url = widget.article.url;
      if (url == null) return;
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Article link copied')));
      return;
    }
    final highlight = await _withComment();
    final eventId = await _ensurePublished(highlight);
    final link = await ProfileService.instance.quoteLink(eventId);
    if (link == null) return;
    await _record('link', ref: eventId);
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Link copied: $link')));
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final article = widget.article;
    final highlight = await _withComment();
    final done = <String>[];
    final failed = <String>[];

    if (_toProfile && _hasProfile) {
      try {
        final result = await ProfileService.instance
            .publishHighlight(article, highlight);
        await _record('profile', ref: result.eventId);
        done.add(result.accepted > 0 ? 'profile' : 'profile (queued)');
      } catch (e) {
        failed.add('profile: $e');
      }
    }

    if (_toTwitter && _twitterUsable) {
      final quoteId = TwitterService.tweetIdFromUrl(article.url);
      final text = ShareActions.highlightsBody(article, [highlight],
          withAttribution: quoteId == null);
      try {
        await SyncService.instance.twitter
            .postTweet(text, quoteTweetId: quoteId);
        await _record('twitter');
        done.add('twitter');
      } catch (e) {
        await OutboxService.instance
            .enqueueTweet(text, quoteTweetId: quoteId, error: '$e');
        await _record('twitter');
        done.add('twitter (queued)');
      }
    }

    for (final contact
        in _contacts.where((c) => _toContacts.contains(c.id))) {
      final body = ShareActions.highlightsBody(article, [highlight]);
      try {
        await ProfileService.instance.sendShareEmail(
          to: contact.address,
          subject: ShareActions.highlightsSubject(article, 1),
          text: body,
        );
        await _record('email', recipient: contact.name);
        done.add(contact.name);
      } catch (e) {
        failed.add('${contact.name}: $e');
      }
    }

    // The mail app opens last so it doesn't interrupt the other sends.
    if (_toComposeEmail && mounted) {
      await ShareActions.byEmail(
        context,
        subject: ShareActions.highlightsSubject(article, 1),
        body: ShareActions.highlightsBody(article, [highlight]),
      );
      await _record('email');
      done.add('email');
    }

    if (!mounted) return;
    setState(() => _sharing = false);
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    final message = failed.isEmpty
        ? (done.isEmpty ? 'Nothing selected' : 'Shared: ${done.join(', ')}')
        : 'Shared: ${done.join(', ')} — failed: ${failed.join('; ')}';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openPitch() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PluginPitchScreen()));
    _load();
  }

  Widget _checkRow({
    required bool value,
    required ValueChanged<bool> onChanged,
    required String label,
    String? trailing,
    bool enabled = true,
    VoidCallback? onLockedTap,
  }) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : onLockedTap,
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
    if (!_loaded) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Share highlight')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(left: 12),
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.highlight.text,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 15, height: 1.4)),
                      const SizedBox(height: 4),
                      Text(widget.article.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _comment,
                  maxLines: 4,
                  minLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Add a comment (optional)',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
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
                      border: Border.all(
                          width: 1.5, style: BorderStyle.solid),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Create your public profile',
                            style:
                                TextStyle(fontWeight: FontWeight.w700)),
                        const Text(
                            'A page people can follow — your highlights and '
                            'comments at einkreader.app/you. Free.',
                            style: TextStyle(fontSize: 12.5)),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () async {
                            await Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const ProfileScreen()));
                            _load();
                          },
                          child: const Text('Create profile'),
                        ),
                      ],
                    ),
                  ),
                _checkRow(
                  value: _toComposeEmail,
                  onChanged: (v) => setState(() => _toComposeEmail = v),
                  label: 'Compose an email…',
                  trailing: 'your mail app',
                ),
                InkWell(
                  onTap: _copyLink,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.link, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(
                                _hasProfile
                                    ? 'Copy link to this quote'
                                    : 'Copy article link',
                                style: const TextStyle(fontSize: 15))),
                        const Icon(Icons.copy, size: 16, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 28),
                _checkRow(
                  value: _toTwitter,
                  onChanged: (v) => setState(() => _toTwitter = v),
                  label: 'Tweet it',
                  enabled: _twitterUsable,
                  trailing: _twitterUsable
                      ? (TwitterService.tweetIdFromUrl(widget.article.url) !=
                              null
                          ? 'quote-tweet'
                          : null)
                      : (_supporter ? 'connect Twitter ›' : 'plugin ›'),
                  onLockedTap: _supporter ? null : _openPitch,
                ),
                for (final contact in _contacts)
                  _checkRow(
                    value: _toContacts.contains(contact.id),
                    onChanged: (v) => setState(() {
                      if (v) {
                        _toContacts.add(contact.id!);
                      } else {
                        _toContacts.remove(contact.id);
                      }
                    }),
                    label: '${contact.name} — one tap',
                    enabled: _emailPluginOn && contact.channel == 'email',
                    trailing: contact.channel == 'nostr'
                        ? 'nostr dm — soon'
                        : (_emailPluginOn ? 'from your address' : 'plugin ›'),
                    onLockedTap: contact.channel == 'nostr'
                        ? null
                        : (_supporter ? null : _openPitch),
                  ),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const ContactsScreen()));
                    _load();
                  },
                  icon: const Icon(Icons.person_add_outlined, size: 18),
                  label: const Text('Add contact'),
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: _sharing ? null : _share,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(width: 2),
                  ),
                  child: Text(_sharing ? 'Sharing…' : 'Share',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
