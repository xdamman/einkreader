import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/errors.dart';
import '../services/nostr_service.dart';
import '../services/sync_service.dart';
import '../widgets/markdown_view.dart';

/// Nostr profiles already fetched this session (hex pubkey → profile), so
/// avatars and names don't refetch when moving between feedback screens.
class NostrProfileCache {
  NostrProfileCache._();
  static final Map<String, NostrProfile> _profiles = {};

  static NostrProfile? get(String pubkey) => _profiles[pubkey];

  /// Fetches whichever of [pubkeys] aren't cached yet (one query).
  static Future<void> load(Iterable<String> pubkeys,
      {NostrService? nostr}) async {
    final missing = pubkeys.where((p) => !_profiles.containsKey(p)).toSet();
    if (missing.isEmpty) return;
    try {
      _profiles.addAll(await (nostr ?? NostrService()).fetchProfiles(missing));
    } catch (_) {
      // Offline or relays down: names fall back to short npubs.
    }
  }

  @visibleForTesting
  static void debugPut(NostrProfile profile) =>
      _profiles[profile.pubkey] = profile;

  @visibleForTesting
  static void debugClear() => _profiles.clear();
}

/// Display name for a pubkey: its profile name, else a shortened npub.
String nostrDisplayName(String pubkey) {
  final name = NostrProfileCache.get(pubkey)?.name ?? '';
  if (name.isNotEmpty) return name;
  final npub = NostrService.npubEncode(pubkey);
  return '${npub.substring(0, 10)}…${npub.substring(npub.length - 4)}';
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
Future<void> openNostrProfile(BuildContext context, String pubkey) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NostrProfileScreen(pubkey: pubkey)));

/// Anyone's Nostr profile, read-only: picture, name, bio, npub, their
/// recent notes, and a Follow button that adds their notes and long reads
/// as sources.
class NostrProfileScreen extends StatefulWidget {
  final String pubkey; // hex

  /// Test seam: supplies the recent notes instead of querying relays.
  final Future<List<NostrItem>> Function(String npub)? loadNotes;

  const NostrProfileScreen({super.key, required this.pubkey, this.loadNotes});

  /// Test seam for screens opened via [openNostrProfile].
  @visibleForTesting
  static Future<List<NostrItem>> Function(String npub)? debugLoadNotes;

  @override
  State<NostrProfileScreen> createState() => _NostrProfileScreenState();
}

class _NostrProfileScreenState extends State<NostrProfileScreen> {
  final _db = AppDatabase.instance;
  late final String _npub = NostrService.npubEncode(widget.pubkey);
  List<NostrItem>? _notes;
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
      appBar: AppBar(title: Text(name)),
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
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
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
          ),
          const SizedBox(height: 24),
          const Text('RECENT NOTES',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2)),
          const Divider(height: 16),
          if (_error != null)
            Text(_error!)
          else if (_notes == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_notes!.isEmpty)
            const Text('No recent notes.')
          else
            for (final note in _notes!) ...[
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
