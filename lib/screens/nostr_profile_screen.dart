import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/errors.dart';
import '../services/feedback_service.dart';
import '../services/nostr_service.dart';
import '../services/profile_service.dart';
import '../services/sync_service.dart';
import '../widgets/markdown_view.dart';
import 'feedback_screen.dart';
import 'profile_screen.dart';

/// Nostr profiles by hex pubkey, kept in memory and in the local database:
/// names and avatars show at once (even offline) and are refreshed from
/// the relays in the background, once per session per person.
class NostrProfileCache {
  NostrProfileCache._();
  static final Map<String, NostrProfile> _profiles = {};
  static final Set<String> _refreshed = {};
  static bool _storedLoaded = false;

  static NostrProfile? get(String pubkey) => _profiles[pubkey];

  /// Makes [pubkeys]' profiles available: stored ones immediately, missing
  /// ones fetched (one query), and every one refreshed once per session.
  /// Returns once the stored and missing ones are in.
  static Future<void> load(Iterable<String> pubkeys,
      {NostrService? nostr}) async {
    final wanted = pubkeys.toSet();
    await _loadStored();
    final missing = wanted.where((p) => !_profiles.containsKey(p)).toSet();
    final stale = wanted.difference(missing).difference(_refreshed);
    if (missing.isNotEmpty) await _fetch(missing, nostr);
    if (stale.isNotEmpty) unawaited(_fetch(stale, nostr));
  }

  static Future<void> _fetch(Set<String> pubkeys, NostrService? nostr) async {
    _refreshed.addAll(pubkeys);
    try {
      final fetched =
          await (nostr ?? NostrService()).fetchProfiles(pubkeys);
      _profiles.addAll(fetched);
      await AppDatabase.instance.saveNostrProfiles({
        for (final p in fetched.values)
          p.pubkey: jsonEncode({
            'name': p.name,
            'about': p.about,
            'picture': p.picture,
            'nip05': p.nip05,
          }),
      });
    } catch (_) {
      // Offline or relays down: stored names (or "Anonymous") stay.
      _refreshed.removeAll(pubkeys);
    }
  }

  static Future<void> _loadStored() async {
    if (_storedLoaded) return;
    _storedLoaded = true;
    try {
      final stored = await AppDatabase.instance.nostrProfiles();
      stored.forEach((pubkey, json) {
        if (_profiles.containsKey(pubkey)) return;
        final m = jsonDecode(json) as Map<String, dynamic>;
        _profiles[pubkey] = NostrProfile(
          pubkey: pubkey,
          name: m['name'] as String? ?? '',
          about: m['about'] as String? ?? '',
          picture: m['picture'] as String? ?? '',
          nip05: m['nip05'] as String? ?? '',
        );
      });
    } catch (_) {
      // No database (e.g. some tests): memory only.
    }
  }

  /// Adds a profile known locally (e.g. the reader's own, right after
  /// posting) without a relay round trip.
  static void put(NostrProfile profile) {
    _profiles[profile.pubkey] = profile;
    _refreshed.add(profile.pubkey); // known-fresh: no background refetch
  }

  @visibleForTesting
  static void debugPut(NostrProfile profile) => put(profile);

  @visibleForTesting
  static void debugClear() {
    _profiles.clear();
    _refreshed.clear();
    _storedLoaded = false;
  }
}

/// Display name for a pubkey: its profile name, else "Anonymous" (never an
/// npub — a key means nothing to a reader).
String nostrDisplayName(String pubkey) {
  final name = NostrProfileCache.get(pubkey)?.name ?? '';
  return name.isNotEmpty ? name : 'Anonymous';
}

/// Round avatar: the profile picture, or the name's initial when there is
/// none (or it fails to load — common offline).
class NostrAvatar extends StatelessWidget {
  final String pubkey;
  final double size;

  const NostrAvatar({super.key, required this.pubkey, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final picture = NostrProfileCache.get(pubkey)?.picture ?? '';
    final initial = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(width: 1.5),
      ),
      child: Text(
        nostrDisplayName(pubkey).characters.first.toUpperCase(),
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700),
      ),
    );
    if (picture.isEmpty) return initial;
    return ClipOval(
      child: Image.network(
        picture,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => initial,
      ),
    );
  }
}

/// Opens [pubkey]'s profile natively (not in a browser or another app).
/// The reader's own ([me]) opens their own profile screen.
Future<void> openNostrProfile(BuildContext context, String pubkey,
        {String? me}) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => pubkey == me
            ? const ProfileScreen()
            : NostrProfileScreen(pubkey: pubkey)));

/// Anyone's Nostr profile, read-only — the app's view of their public
/// page: picture, name, bio, npub, the highlights they shared, the
/// feedback they posted about einkreader, their recent notes, and a Follow
/// button that adds their notes and long reads as sources.
class NostrProfileScreen extends StatefulWidget {
  final String pubkey; // hex

  /// Test seam: supplies the recent notes instead of querying relays.
  final Future<List<NostrItem>> Function(String npub)? loadNotes;

  const NostrProfileScreen({super.key, required this.pubkey, this.loadNotes});

  /// Test seam for screens opened via [openNostrProfile].
  @visibleForTesting
  static Future<List<NostrItem>> Function(String npub)? debugLoadNotes;

  /// Test seam: the author's shared highlights (kind 9802) and feedback
  /// notes, as raw events, instead of querying relays.
  @visibleForTesting
  static Future<List<Map<String, dynamic>>> Function(String pubkey)?
      debugLoadActivity;

  @override
  State<NostrProfileScreen> createState() => _NostrProfileScreenState();
}

class _NostrProfileScreenState extends State<NostrProfileScreen> {
  final _db = AppDatabase.instance;
  late final String _npub = NostrService.npubEncode(widget.pubkey);
  List<NostrItem>? _notes;
  List<Map<String, dynamic>> _highlights = [];
  List<FeedbackNote> _feedback = [];
  bool _following = false;
  bool _followBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await NostrProfileCache.load([widget.pubkey]);
    final sources = await _db.getSources();
    if (!mounted) return;
    setState(() {
      _following = sources.any((s) =>
          s.url == _npub &&
          (s.type == SourceType.nostrNotes ||
              s.type == SourceType.nostrLongReads));
    });
    // Highlights and feedback fill in alongside the notes; a failure there
    // only leaves those sections out.
    unawaited(_loadActivity());
    try {
      final notes = await (widget.loadNotes ??
          NostrProfileScreen.debugLoadNotes ??
          (npub) => NostrService().fetchAuthorNotes(npub))(_npub);
      if (!mounted) return;
      setState(() => _notes = notes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e, doing: 'loading notes'));
    }
  }

  Future<void> _loadActivity() async {
    try {
      final events = await (NostrProfileScreen.debugLoadActivity ??
          (pubkey) async {
            final nostr = NostrService();
            final results = await Future.wait([
              nostr.fetchHighlightEvents(pubkey),
              nostr.query({
                'kinds': [1],
                'authors': [pubkey],
                '#p': [FeedbackService.officialHex],
                'limit': 50,
              }),
            ]);
            return [...results[0], ...results[1]];
          })(widget.pubkey);
      final highlights = events
          .where((e) => e['kind'] == 9802 && e['pubkey'] == widget.pubkey)
          .toList()
        ..sort((a, b) => ((b['created_at'] as int?) ?? 0)
            .compareTo((a['created_at'] as int?) ?? 0));
      final feedback = events
          .where((e) => e['kind'] == 1 && e['pubkey'] == widget.pubkey)
          .map(FeedbackNote.fromEvent)
          .where((n) => n.rootId == null)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _highlights = highlights;
        _feedback = feedback;
      });
    } catch (_) {
      // Offline or relays down: the notes section says so already.
    }
  }

  /// Recent notes minus the feedback, which has its own section.
  List<NostrItem> get _otherNotes {
    final feedbackIds = {for (final n in _feedback) n.id};
    return [
      for (final n in _notes ?? const <NostrItem>[])
        if (!feedbackIds.contains(n.id)) n
    ];
  }

  /// Their page on the einkreader site, when they registered a name there.
  static Uri? _publicPage(NostrProfile? profile) {
    const suffix = '@${ProfileService.nip05Domain}';
    final nip05 = profile?.nip05.toLowerCase() ?? '';
    if (!nip05.endsWith(suffix)) return null;
    final name = nip05.substring(0, nip05.length - suffix.length);
    return name.isEmpty
        ? null
        : Uri.https(ProfileService.nip05Domain, '/$name');
  }

  static String? _tag(Map<String, dynamic> event, String name) {
    for (final tag in (event['tags'] as List? ?? const [])) {
      final t = (tag as List).map((e) => '$e').toList();
      if (t.length >= 2 && t[0] == name && t[1].trim().isNotEmpty) {
        return t[1].trim();
      }
    }
    return null;
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
            const Divider(height: 16),
          ],
        ),
      );

  Widget _highlightTile(Map<String, dynamic> event) {
    final title = _tag(event, 'title');
    final comment = _tag(event, 'comment');
    final created = DateTime.fromMillisecondsSinceEpoch(
        ((event['created_at'] as int?) ?? 0) * 1000);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
                border: Border(left: BorderSide(width: 3))),
            child: Text((event['content'] as String?) ?? '',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontStyle: FontStyle.italic, height: 1.4)),
          ),
          if (comment != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(comment, style: const TextStyle(fontSize: 15)),
            ),
          Text(relativeTime(created), style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _feedbackTile(FeedbackNote note) => InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => FeedbackThreadScreen(root: note))),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.subject != null)
                Text(note.subject!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              if (note.displayText.isNotEmpty)
                Text(plainPreview(note.displayText),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, height: 1.4)),
              Text(relativeTime(note.createdAt),
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );

  Future<void> _follow() async {
    setState(() => _followBusy = true);
    try {
      final name = nostrDisplayName(widget.pubkey);
      final now = DateTime.now().millisecondsSinceEpoch;
      final sources = [
        await _db.insertSource(Source(
            type: SourceType.nostrNotes,
            title: '$name · Notes',
            url: _npub,
            createdAt: now)),
        await _db.insertSource(Source(
            type: SourceType.nostrLongReads,
            title: '$name · Long reads',
            url: _npub,
            createdAt: now)),
      ];
      unawaited(SyncService.instance.syncSources(sources));
      if (!mounted) return;
      setState(() => _following = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Following $name — their notes and long reads '
              'will appear in your feed')));
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = NostrProfileCache.get(widget.pubkey);
    final name = nostrDisplayName(widget.pubkey);
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          // Loading shows here, not as a big spinner in the page.
          if (_notes == null && _error == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          Row(
            children: [
              NostrAvatar(pubkey: widget.pubkey, size: 72),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700)),
                    if ((profile?.nip05 ?? '').isNotEmpty)
                      Text(profile!.nip05,
                          style: const TextStyle(fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          if ((profile?.about ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(profile!.about,
                style: const TextStyle(fontSize: 16, height: 1.4)),
          ],
          const SizedBox(height: 12),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _npub));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('npub copied')));
            },
            child: Row(
              children: [
                Expanded(
                  child: Text(_npub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontFamily: 'monospace')),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.copy, size: 16),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: Icon(_following ? Icons.check : Icons.add),
                label: Text(_following
                    ? 'Following'
                    : _followBusy
                        ? 'Following…'
                        : 'Follow'),
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(width: 1.5)),
                onPressed: _following || _followBusy ? null : _follow,
              ),
              if (_publicPage(profile) case final page?)
                OutlinedButton.icon(
                  icon: const Icon(Icons.public),
                  label: const Text('Public page'),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(width: 1.5)),
                  onPressed: () =>
                      launchUrl(page, mode: LaunchMode.externalApplication),
                ),
            ],
          ),
          if (_highlights.isNotEmpty) ...[
            _heading('SHARED HIGHLIGHTS · ${_highlights.length}'),
            for (final event in _highlights) _highlightTile(event),
          ],
          if (_feedback.isNotEmpty) ...[
            _heading('FEEDBACK · ${_feedback.length}'),
            for (final note in _feedback) _feedbackTile(note),
          ],
          _heading('RECENT NOTES'),
          if (_error != null)
            Text(_error!)
          else if (_notes == null)
            const SizedBox.shrink()
          else if (_otherNotes.isEmpty)
            const Text('No recent notes.')
          else
            for (final note in _otherNotes) ...[
              if (note.createdAt != null)
                Text(relativeTime(note.createdAt!),
                    style: const TextStyle(fontSize: 13)),
              MarkdownView(markdown: note.content, fontSize: 16),
              const Divider(height: 24),
            ],
        ],
      ),
    );
  }
}

/// "just now", "5m", "3h", "2d", then a date.
String relativeTime(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[time.month - 1]} ${time.day}, ${time.year}';
}
