import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import 'app_log.dart';
import 'nostr_service.dart';
import 'outbox_service.dart';
import 'profile_service.dart';

/// One public note (kind 1) in the feedback space, with what the reader
/// needs to show it: who wrote it, where it sits in a thread, and the emoji
/// reactions it got.
class FeedbackNote {
  final String id;
  final String pubkey; // hex
  final String content;
  final DateTime createdAt;

  /// Thread root (NIP-10 "root" e-tag); null for a top-level feedback.
  final String? rootId;

  /// The note this one answers (NIP-10 "reply" e-tag, or the root).
  final String? replyToId;

  /// emoji → pubkeys (hex) that reacted with it.
  final Map<String, Set<String>> reactions;

  /// emoji → pubkey → when they reacted, for "who reacted" (long press).
  final Map<String, Map<String, DateTime>> reactedAt;

  /// NIP-14 subject, when the note has one.
  final String? subject;

  /// Attached images (NIP-92 imeta, or bare image links in the text).
  final List<String> images;

  /// Hashtags (`t` tags), lowercase: "feedback", and a kind such as "bug".
  final List<String> tags;

  FeedbackNote({
    required this.id,
    required this.pubkey,
    required this.content,
    required this.createdAt,
    this.rootId,
    this.replyToId,
    this.subject,
    this.images = const [],
    this.tags = const [],
    this.sending = false,
    Map<String, Set<String>>? reactions,
    Map<String, Map<String, DateTime>>? reactedAt,
  })  : reactions = reactions ?? {},
        reactedAt = reactedAt ?? {};

  /// Adds one reaction (the earliest time wins if they reacted twice).
  void addReaction(String emoji, String pubkey, DateTime at) {
    reactions.putIfAbsent(emoji, () => <String>{}).add(pubkey);
    final times = reactedAt.putIfAbsent(emoji, () => {});
    final known = times[pubkey];
    if (known == null || at.isBefore(known)) times[pubkey] = at;
  }

  void removeReaction(String emoji, String pubkey) {
    reactions[emoji]?.remove(pubkey);
    reactedAt[emoji]?.remove(pubkey);
    if (reactions[emoji]?.isEmpty ?? false) {
      reactions.remove(emoji);
      reactedAt.remove(emoji);
    }
  }

  /// NIP-27 mentions in the text: `nostr:npub1…`.
  static final mentionPattern =
      RegExp(r'nostr:(npub1[02-9ac-hj-np-z]{58})');

  /// Pubkeys (hex) @mentioned in the text.
  Set<String> get mentioned => mentionedIn(content);

  static Set<String> mentionedIn(String text) => {
        for (final m in mentionPattern.allMatches(text))
          if (_tryDecode(m.group(1)!) case final hex?) hex,
      };

  static String? _tryDecode(String npub) {
    try {
      return NostrService.decodeNpub(npub);
    } catch (_) {
      return null;
    }
  }

  /// [text] with each mention as a markdown link, `[@Name](nostr:npub1…)`,
  /// named by [nameOf] (pubkey hex → display name).
  static String linkMentions(String text, String Function(String) nameOf) =>
      text.replaceAllMapped(mentionPattern, (m) {
        final hex = _tryDecode(m.group(1)!);
        if (hex == null) return m.group(0)!;
        final name = nameOf(hex).replaceAll(RegExp(r'[\[\]]'), '');
        return '[@$name](${m.group(0)})';
      });

  /// What the reader typed, with each "@Name" they picked from the
  /// suggestions ([picked]: name → pubkey hex) turned into a NIP-27
  /// mention.
  static String encodeMentions(String typed, Map<String, String> picked) {
    var text = typed;
    // Longest names first, so "@Ann Lee" isn't eaten by "@Ann".
    final names = picked.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final name in names) {
      final token = '@$name';
      if (!text.contains(token)) continue;
      text = text.replaceAll(
          token, 'nostr:${NostrService.npubEncode(picked[name]!)}');
    }
    return text;
  }

  /// A just-written note still on its way (screenshot uploading, relays
  /// not answered yet): shown in the list, not yet something to open,
  /// reply to or react to.
  final bool sending;

  static final _imageUrl = RegExp(
      r'https?://\S+\.(?:png|jpe?g|gif|webp)(?:\?\S*)?',
      caseSensitive: false);

  /// The text to show under the subject: the content without the subject
  /// line it starts with (other clients need it there) and without the
  /// image links (shown as images instead).
  String get displayText {
    var text = content;
    final s = subject;
    if (s != null && text.startsWith(s)) text = text.substring(s.length);
    for (final image in images) {
      text = text.replaceAll(image, '');
    }
    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static FeedbackNote fromEvent(Map<String, dynamic> event) {
    String? root;
    String? reply;
    final positional = <String>[];
    for (final tag in (event['tags'] as List? ?? const [])) {
      final t = (tag as List).map((e) => '$e').toList();
      if (t.length < 2 || t[0] != 'e') continue;
      final marker = t.length >= 4 ? t[3] : '';
      if (marker == 'root') {
        root = t[1];
      } else if (marker == 'reply') {
        reply = t[1];
      } else if (marker != 'mention') {
        positional.add(t[1]);
      }
    }
    // Deprecated positional e-tags (NIP-10): first = root, last = reply.
    if (root == null && positional.isNotEmpty) root = positional.first;
    if (reply == null && positional.length > 1) reply = positional.last;
    String? subject;
    final images = <String>[];
    final hashtags = <String>[];
    for (final tag in (event['tags'] as List? ?? const [])) {
      final t = (tag as List).map((e) => '$e').toList();
      if (t.length >= 2 && t[0] == 'subject' && t[1].trim().isNotEmpty) {
        subject = t[1].trim();
      } else if (t.length >= 2 && t[0] == 't' && t[1].trim().isNotEmpty) {
        final tag = t[1].trim().toLowerCase();
        if (!hashtags.contains(tag)) hashtags.add(tag);
      } else if (t.isNotEmpty && t[0] == 'imeta') {
        for (final part in t.skip(1)) {
          if (part.startsWith('url ')) images.add(part.substring(4).trim());
        }
      }
    }
    final content = (event['content'] as String?) ?? '';
    for (final m in _imageUrl.allMatches(content)) {
      if (!images.contains(m.group(0))) images.add(m.group(0)!);
    }
    return FeedbackNote(
      id: event['id'] as String,
      pubkey: event['pubkey'] as String,
      content: content,
      subject: subject,
      images: images,
      tags: hashtags,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          ((event['created_at'] as int?) ?? 0) * 1000),
      rootId: root,
      replyToId: reply ?? root,
    );
  }
}

/// The hashtag on every feedback note.
const feedbackTag = 'feedback';

/// Also on every feedback note: unlike #feedback, a hashtag only einkreader
/// uses, so any Nostr app can follow the feedback by it.
const appTag = 'einkreader';

/// What a feedback is about, picked when writing it and offered as a
/// filter on the list. Stored as a hashtag (`t` tag).
enum FeedbackKind {
  bug('bug', 'Bug'),
  feature('feature-request', 'Feature request'),
  rendering('rendering-issue', 'Rendering issue'),

  /// What's new in a release. Anyone can put the hashtag on a note, so
  /// the app counts it only from the maintainers' accounts.
  releaseNotes('release-notes', 'Release notes', maintainersOnly: true);

  final String tag;
  final String label;
  final bool maintainersOnly;
  const FeedbackKind(this.tag, this.label, {this.maintainersOnly = false});

  /// Whether [note] is of this kind: tagged with it, and for
  /// [maintainersOnly] kinds, written by a maintainer.
  bool matches(FeedbackNote note) =>
      note.tags.contains(tag) &&
      (!maintainersOnly || FeedbackService.maintainers.contains(note.pubkey));

  /// The kinds [pubkey] may tag a new feedback with.
  static List<FeedbackKind> availableTo(String? pubkey) => [
        for (final kind in values)
          if (!kind.maintainersOnly ||
              FeedbackService.maintainers.contains(pubkey))
            kind,
      ];
}

/// A feedback being posted: the local [draft] to show right away, and
/// [sent], the signed note once it's out (`queued` when it waits in the
/// outbox).
class SentFeedback {
  final FeedbackNote draft;
  final Future<({FeedbackNote note, bool queued})> sent;

  const SentFeedback({required this.draft, required this.sent});
}

/// In-app feedback, held entirely on Nostr: public notes addressed to the
/// app's official account (a "p" tag), threads of replies under them, and
/// NIP-25 emoji reactions. Anyone can read; posting and reacting sign with
/// the reader's own profile key.
class FeedbackService {
  FeedbackService({NostrService? nostr, ProfileService? profile})
      : _nostr = nostr ?? NostrService(),
        _profile = profile ?? ProfileService.instance;

  final NostrService _nostr;
  final ProfileService _profile;

  /// The relays this service reads from, also used to fetch the authors'
  /// profiles.
  NostrService get nostr => _nostr;

  /// einkreader's official Nostr account; feedback is addressed to it.
  static const officialNpub =
      'npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7';
  static final officialHex = NostrService.decodeNpub(officialNpub);

  /// The agent that answers feedback (signs until the official key is
  /// imported). Its Nostr profile still carries an old personal name, so
  /// the app names it itself.
  static const agentHex =
      '735beae7899fa8c1ebe0e81087aeae773d37fba3f189f2c2e7808c7e1387b58f';

  /// Who may publish release notes: the official account, its agent, and
  /// Xavier's own accounts (the einkreader profile and his personal one).
  static final maintainers = {
    officialHex,
    agentHex,
    '8256dcc06b7399551b35752afd9dc774eab545d01886065023d7f178cd293fe2',
    '340254e011abda2e82585cbfee4f91b3f07549a6c468fe009bf3ec7665a2e31b',
  };

  /// Names the app shows for its own accounts, whatever their profile says.
  static const knownNames = {agentHex: 'einkReader agent'};

  final AppDatabase _db = AppDatabase.instance;

  /// Top-level feedback from the local cache only — instant, no network.
  /// Newest first, with reactions and reply counts.
  Future<({List<FeedbackNote> notes, Map<String, int> replyCounts})>
      cachedFeedback() async {
    await _loadAddressed();
    final notes = (await _db.nostrEvents([1]))
        .map(FeedbackNote.fromEvent)
        .toList();
    final roots = notes
        .where((n) =>
            n.rootId == null && n.pubkey.isNotEmpty && _addressedToUs(n))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final rootIds = {for (final r in roots) r.id};
    final replyCounts = <String, int>{};
    for (final note in notes) {
      final root = note.rootId;
      if (root != null && rootIds.contains(root)) {
        replyCounts[root] = (replyCounts[root] ?? 0) + 1;
      }
    }
    await _attachReactions(roots);
    return (notes: roots, replyCounts: replyCounts);
  }

  final Set<String> _addressed = {};

  bool _addressedToUs(FeedbackNote note) => _addressed.contains(note.id);

  /// Asks the relays only for what's newer than the cache (a few minutes
  /// of overlap for clock skew), stores it, and returns the refreshed list.
  Future<({List<FeedbackNote> notes, Map<String, int> replyCounts})>
      feedback() async {
    await _loadAddressed();
    // Bounded by the last successful sync — not by the newest stored event:
    // our own posts are stored the moment they're signed, which would hide
    // everything older that we never fetched. A day of overlap is cheap.
    final prefs = await SharedPreferences.getInstance();
    final syncedAt = prefs.getInt(_kSyncedAt);
    final startedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Once a day, the whole history again: a relay that was slow on one
    // sync must not leave older feedback (and its replies) missing for good.
    final fullAt = prefs.getInt(_kFullSyncAt);
    final full = fullAt == null || startedAt - fullAt > 86400;
    final since = syncedAt == null || full ? null : syncedAt - 86400;
    final fresh = await _nostr.query({
      'kinds': [1],
      '#p': [officialHex],
      'limit': 200,
      if (since != null) 'since': since,
    });
    await _db.saveNostrEvents(fresh);
    _addressed.addAll(_idsAddressedToUs(fresh));
    // An empty answer on a first sync is more likely unreachable relays
    // than no feedback at all: don't mark it synced, so the next refresh
    // asks for everything again.
    if (fresh.isNotEmpty || syncedAt != null) {
      await prefs.setInt(_kSyncedAt, startedAt);
      if (full && fresh.isNotEmpty) await prefs.setInt(_kFullSyncAt, startedAt);
    }
    final rootIds = (await cachedFeedback()).notes.map((n) => n.id).toList();
    if (rootIds.isNotEmpty) {
      final more = await _nostr.query({
        'kinds': [1, 7],
        '#e': rootIds,
        if (since != null) 'since': since,
      });
      await _db.saveNostrEvents(more);
      // Reactions to replies need the reply ids too.
      final replyIds = (await _db.nostrEvents([1]))
          .map(FeedbackNote.fromEvent)
          .where((n) => n.rootId != null && rootIds.contains(n.rootId))
          .map((n) => n.id)
          .toList();
      if (replyIds.isNotEmpty) {
        await _db.saveNostrEvents(await _nostr.query({
          'kinds': [7],
          '#e': replyIds,
          if (since != null) 'since': since,
        }));
      }
    }
    return cachedFeedback();
  }

  static const _kSyncedAt = 'feedback_synced_at';
  static const _kFullSyncAt = 'feedback_full_sync_at';

  /// Which notes are feedback (tag the official account) — recomputed from
  /// the cache once per service, then kept up to date as events arrive.
  Future<void> _loadAddressed() async {
    if (_addressed.isNotEmpty) return;
    _addressed.addAll(_idsAddressedToUs(await _db.nostrEvents([1])));
  }

  static Iterable<String> _idsAddressedToUs(
          Iterable<Map<String, dynamic>> events) =>
      events
          .where((e) => (e['tags'] as List? ?? const []).any((t) =>
              (t as List).length >= 2 && t[0] == 'p' && t[1] == officialHex))
          .map((e) => e['id'] as String);

  /// A feedback thread from the cache only (root first, then replies).
  Future<List<FeedbackNote>> cachedThread(String rootId) async {
    final byId = <String, FeedbackNote>{};
    for (final event in await _db.nostrEvents([1])) {
      final note = FeedbackNote.fromEvent(event);
      if (note.id == rootId || note.rootId == rootId) byId[note.id] = note;
    }
    final notes = byId.values.toList()
      ..sort((a, b) {
        if (a.id == rootId) return -1;
        if (b.id == rootId) return 1;
        return a.createdAt.compareTo(b.createdAt);
      });
    await _attachReactions(notes);
    return notes;
  }

  /// A feedback note and every reply under it, oldest first (root first):
  /// fetches what's new for this thread, then reads the cache.
  Future<List<FeedbackNote>> thread(String rootId) async {
    final cached = await cachedThread(rootId);
    final latest = cached.isEmpty
        ? null
        : cached
            .map((n) => n.createdAt.millisecondsSinceEpoch ~/ 1000)
            .reduce((a, b) => a > b ? a : b);
    final since = latest == null ? null : latest - 300;
    final results = await Future.wait([
      if (cached.isEmpty)
        _nostr.query({
          'ids': [rootId],
        }),
      _nostr.query({
        'kinds': [1],
        '#e': [rootId],
        if (since != null) 'since': since,
      }),
    ]);
    for (final events in results) {
      await _db.saveNostrEvents(events);
    }
    final ids = (await cachedThread(rootId)).map((n) => n.id).toList();
    await _db.saveNostrEvents(await _nostr.query({
      'kinds': [7],
      '#e': ids,
      if (since != null) 'since': since,
    }));
    return cachedThread(rootId);
  }

  Future<void> _attachReactions(List<FeedbackNote> notes) async {
    if (notes.isEmpty) return;
    final byId = {for (final n in notes) n.id: n};
    for (final note in notes) {
      note.reactions.clear();
      note.reactedAt.clear();
    }
    for (final event in await _db.nostrEvents([7])) {
      final tags = (event['tags'] as List? ?? const [])
          .map((t) => (t as List).map((e) => '$e').toList())
          .where((t) => t.length >= 2 && t[0] == 'e')
          .toList();
      if (tags.isEmpty) continue;
      // NIP-25: the last e-tag is the reacted-to note.
      final note = byId[tags.last[1]];
      if (note == null) continue;
      var emoji = ((event['content'] as String?) ?? '').trim();
      if (emoji.isEmpty || emoji == '+') emoji = '❤️';
      if (emoji == '-') continue; // a dislike, not shown
      note.addReaction(
          emoji,
          event['pubkey'] as String,
          DateTime.fromMillisecondsSinceEpoch(
              ((event['created_at'] as int?) ?? 0) * 1000));
    }
  }

  /// Keeps an event we signed ourselves in the cache, so it shows at once.
  Future<void> _remember(Map<String, dynamic> event) async {
    await _db.saveNostrEvents([event]);
    _addressed.addAll(_idsAddressedToUs([event]));
  }

  /// How many replies and reactions to the reader's own feedback they
  /// haven't seen yet, for the badge on the feedback icon. Updated by
  /// [unseenByThread].
  static final ValueNotifier<int> unseenCount = ValueNotifier(0);

  static const _kSeenBaseline = 'feedback_seen_baseline';
  static const _kThreadSeen = 'feedback_thread_seen';

  /// Replies and reactions from others to the reader's notes, newer than
  /// when they last opened that thread: thread root id → count. Only
  /// counts activity after the first time this ran, so installing or
  /// updating doesn't light up old history. Cache only, no network.
  Future<Map<String, int>> unseenByThread() async {
    final me = await myPubkey;
    if (me == null) {
      unseenCount.value = 0;
      return const {};
    }
    final prefs = await SharedPreferences.getInstance();
    var baseline = prefs.getInt(_kSeenBaseline);
    if (baseline == null) {
      baseline = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await prefs.setInt(_kSeenBaseline, baseline);
    }
    final seen = _threadSeen(prefs);

    final notes = {
      for (final e in await _db.nostrEvents([1]))
        e['id'] as String: FeedbackNote.fromEvent(e)
    };
    final mine = {
      for (final n in notes.values)
        if (n.pubkey == me) n.id
    };
    final out = <String, int>{};
    void count(String thread, int createdAt) {
      if (createdAt <= (seen[thread] ?? baseline!)) return;
      out[thread] = (out[thread] ?? 0) + 1;
    }

    for (final e in await _db.nostrEvents([1, 7])) {
      if (e['pubkey'] == me) continue;
      final createdAt = (e['created_at'] as int?) ?? 0;
      final ids = [
        for (final tag in (e['tags'] as List? ?? const []))
          if ((tag as List).length >= 2 && tag[0] == 'e') '${tag[1]}'
      ];
      if (ids.isEmpty) continue;
      if (e['kind'] == 1) {
        if (!ids.any(mine.contains)) continue;
        final note = notes[e['id']];
        count(note?.rootId ?? ids.first, createdAt);
      } else {
        // NIP-25: the last e-tag is the reacted-to note.
        final target = ids.last;
        if (!mine.contains(target)) continue;
        count(notes[target]?.rootId ?? target, createdAt);
      }
    }
    unseenCount.value = out.values.fold(0, (a, b) => a + b);
    return out;
  }

  static Map<String, int> _threadSeen(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_kThreadSeen);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return {};
    }
  }

  /// The reader opened this thread: its replies and reactions are seen.
  Future<void> markThreadSeen(String rootId) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = _threadSeen(prefs)
      ..[rootId] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await prefs.setString(_kThreadSeen, jsonEncode(seen));
    await unseenByThread();
  }

  /// Fetches what's new from the relays and updates [unseenCount]. For
  /// the home screen, in the background: failures are ignored.
  Future<void> refreshNotifications() async {
    try {
      if (!await canPost) return;
      await unseenByThread();
      await feedback();
      await unseenByThread();
    } catch (_) {}
  }

  /// Whether this install can sign (posting and reacting need a profile).
  Future<bool> get canPost => _profile.enabled;

  /// The reader's own pubkey (hex), to highlight their reactions.
  Future<String?> get myPubkey async =>
      await canPost ? await _profile.publicKeyHex : null;

  /// Who the reader posts as: the active profile's name, address and key,
  /// shown in the new-feedback form so nobody posts under an identity they
  /// didn't expect.
  Future<({String name, String? address, String npub, String picture})>
      identity() async {
    final profile = await _profile.profile();
    return (
      name: profile.name,
      address: await _profile.nip05Address,
      npub: await _profile.npub,
      picture: profile.picture,
    );
  }

  /// Uploads a screenshot (shrunk to 1600px on its long side, JPG) and
  /// returns its public URL.
  Future<String> uploadScreenshot(Uint8List bytes) async {
    final shrunk = await Isolate.run(() => _shrink(bytes));
    return _profile.uploadImage(shrunk, what: 'screenshot');
  }

  static Uint8List _shrink(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longest > 1600
        ? img.copyResize(decoded,
            width: decoded.width >= decoded.height ? 1600 : null,
            height: decoded.height > decoded.width ? 1600 : null)
        : decoded;
    return img.encodeJpg(resized, quality: 85);
  }

  /// Posts new feedback without making the reader wait on the network:
  /// [SentFeedback.draft] is a local copy to show at once, and
  /// [SentFeedback.sent] completes once the screenshot and [images] are
  /// uploaded and the signed note is out, or queued in the outbox when no
  /// relay could be reached (the outbox retries it on the next sync). An
  /// image whose upload fails is left out rather than holding the feedback
  /// back.
  Future<SentFeedback> submit(String body,
      {String? subject,
      String? url,
      Uint8List? screenshot,
      List<Uint8List> images = const [],
      Iterable<FeedbackKind> kinds = const []}) async {
    final local = FeedbackNote.fromEvent({
      'id': 'sending-${DateTime.now().microsecondsSinceEpoch}',
      'pubkey': await _profile.publicKeyHex,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'content': _content(body, subject: subject, url: url),
      'tags': _tags(subject: subject, url: url, kinds: kinds),
    });
    final draft = FeedbackNote(
        id: local.id,
        pubkey: local.pubkey,
        content: local.content,
        createdAt: local.createdAt,
        subject: local.subject,
        tags: local.tags,
        sending: true);

    Future<({FeedbackNote note, bool queued})> send() async {
      final imageUrls = <String>[];
      for (final bytes in [if (screenshot != null) screenshot, ...images]) {
        try {
          imageUrls.add(await uploadScreenshot(bytes));
        } catch (e) {
          await AppLogService.instance
              .warn('Feedback: image upload failed, posting without: $e');
        }
      }
      final event = await _profile.signEvent(
          kind: 1,
          content:
              _content(body, subject: subject, url: url, imageUrls: imageUrls),
          tags: [
            ..._tags(
                subject: subject,
                url: url,
                imageUrls: imageUrls,
                kinds: kinds),
            ['client', 'einkreader'],
          ]);
      final note = FeedbackNote.fromEvent(event);
      final description = 'Feedback: "${draft.subject ?? draft.displayText}"';
      try {
        await _remember(event);
        final accepted = await _nostr.publish(event);
        await AppLogService.instance.info(
            'Feedback: note ${event['id']} accepted by $accepted relay(s)');
        if (accepted > 0) return (note: note, queued: false);
        await OutboxService.instance.enqueueNostrEvent(event,
            description: description, error: 'No relay accepted the note');
      } catch (e) {
        await OutboxService.instance
            .enqueueNostrEvent(event, description: description, error: '$e');
      }
      return (note: note, queued: true);
    }

    return SentFeedback(draft: draft, sent: send());
  }

  /// The note's text: the subject first (NIP-14 tag, also the first line
  /// so every client shows it), then the body, link and image URLs.
  static String _content(String body,
      {String? subject, String? url, List<String> imageUrls = const []}) {
    final s = subject?.trim() ?? '';
    final link = url?.trim() ?? '';
    return [
      if (s.isNotEmpty) s,
      body.trim(),
      if (link.isNotEmpty) link,
      ...imageUrls,
    ].where((part) => part.isNotEmpty).join('\n\n');
  }

  /// Every feedback note carries the "feedback" and "einkreader" hashtags,
  /// plus its kinds.
  static List<List<String>> _tags(
      {String? subject,
      String? url,
      List<String> imageUrls = const [],
      Iterable<FeedbackKind> kinds = const []}) {
    final s = subject?.trim() ?? '';
    final link = url?.trim() ?? '';
    return [
      ['p', officialHex],
      ['t', feedbackTag],
      ['t', appTag],
      for (final kind in FeedbackKind.values)
        if (kinds.contains(kind)) ['t', kind.tag],
      if (s.isNotEmpty) ['subject', s],
      if (link.isNotEmpty) ['r', link],
      for (final imageUrl in imageUrls)
        ['imeta', 'url $imageUrl', 'm image/jpeg'],
    ];
  }

  /// Posts a new top-level feedback note addressed to the official account.
  /// The subject (NIP-14 tag, also the first line so every client shows
  /// it), link and screenshot (NIP-92 imeta, also its URL in the text) are
  /// optional.
  Future<FeedbackNote> post(String body,
          {String? subject, String? url, String? imageUrl}) async =>
      (await _publish(
        content: _content(body,
            subject: subject,
            url: url,
            imageUrls: [if (imageUrl != null) imageUrl]),
        tags: _tags(
            subject: subject,
            url: url,
            imageUrls: [if (imageUrl != null) imageUrl]),
      ))
          .note;

  /// Replies inside a thread (NIP-10 marked e-tags), notifying the author
  /// of the note answered, the official account and anyone @mentioned
  /// (NIP-27 `nostr:npub1…` in [text]). Offline first: when no relay takes
  /// it, the signed reply waits in the outbox (`queued`) and shows in the
  /// thread meanwhile. The same reply to the same note within
  /// [repeatWindow] isn't sent again (`repeated`): the earlier one is
  /// returned instead.
  Future<({FeedbackNote note, bool queued, bool repeated})> reply(
      FeedbackNote to, String text) async {
    final root = to.rootId ?? to.id;
    final earlier = await _recentReply(root, to.id, text.trim());
    if (earlier != null) {
      await AppLogService.instance
          .info('Feedback: same reply already sent, not sending it again');
      return (note: earlier, queued: false, repeated: true);
    }
    final notified = {to.pubkey, officialHex};
    final sent = await _publish(
        content: text,
        tags: [
          ['e', root, '', 'root'],
          if (to.id != root) ['e', to.id, '', 'reply'],
          ['p', to.pubkey],
          if (to.pubkey != officialHex) ['p', officialHex],
          for (final pubkey in FeedbackNote.mentionedIn(text))
            if (notified.add(pubkey)) ['p', pubkey],
        ],
        description: 'Reply: "${text.trim()}"');
    return (note: sent.note, queued: sent.queued, repeated: false);
  }

  /// How long the same reply to the same note counts as a repeat (people
  /// tapping send again when the network is slow).
  static const repeatWindow = Duration(hours: 1);

  /// The reader's own reply with exactly [content] to [replyToId] in
  /// thread [root], sent within [repeatWindow], if any.
  Future<FeedbackNote?> _recentReply(
      String root, String replyToId, String content) async {
    final me = await myPubkey;
    if (me == null) return null;
    final since = DateTime.now().subtract(repeatWindow);
    for (final event in await _db.nostrEvents([1])) {
      if (event['pubkey'] != me || event['content'] != content) continue;
      final note = FeedbackNote.fromEvent(event);
      if (note.rootId == root &&
          note.replyToId == replyToId &&
          note.createdAt.isAfter(since)) {
        return note;
      }
    }
    return null;
  }

  /// Reacts to a note with an emoji (NIP-25) and remembers the choice so
  /// the reader's favorite emojis come first next time. Offline first:
  /// returns true when no relay took it and it waits in the outbox.
  Future<bool> react(FeedbackNote note, String emoji) async {
    final event = await _profile.signEvent(kind: 7, content: emoji, tags: [
      ['e', note.id],
      ['p', note.pubkey],
      ['k', '1'],
    ]);
    await _remember(event);
    await _rememberEmoji(emoji);
    return _sendOrQueue(event, description: 'Reaction $emoji');
  }

  Future<({FeedbackNote note, bool queued})> _publish(
      {required String content,
      required List<List<String>> tags,
      String? description}) async {
    final event = await _profile.signEvent(
        kind: 1,
        content: content.trim(),
        tags: [
          ...tags,
          ['client', 'einkreader'],
        ]);
    await _remember(event);
    final queued = await _sendOrQueue(event,
        description: description ?? 'Feedback: "${content.trim()}"');
    return (note: FeedbackNote.fromEvent(event), queued: queued);
  }

  /// Publishes a signed event; when no relay takes it (offline, relays
  /// down), queues it in the outbox, which re-sends it on the next sync.
  /// Returns whether it was queued.
  Future<bool> _sendOrQueue(Map<String, dynamic> event,
      {required String description}) async {
    try {
      final accepted = await _nostr.publish(event);
      await AppLogService.instance.info(
          'Feedback: event ${event['id']} accepted by $accepted relay(s)');
      if (accepted > 0) return false;
      await OutboxService.instance.enqueueNostrEvent(event,
          description: description, error: 'No relay accepted the event');
    } catch (e) {
      await OutboxService.instance
          .enqueueNostrEvent(event, description: description, error: '$e');
    }
    return true;
  }

  // ------------------------------------------------------- reply drafts

  static const _kReplyDrafts = 'feedback_reply_drafts';

  /// The reply the reader was writing in a thread and didn't send: its
  /// text and the @mentions picked in it (name → pubkey hex).
  static Future<({String text, Map<String, String> picked})?> replyDraft(
      String rootId) async {
    final prefs = await SharedPreferences.getInstance();
    final draft = _replyDrafts(prefs)[rootId];
    if (draft is! Map) return null;
    final text = draft['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final picked = draft['picked'];
    return (
      text: text,
      picked: picked is Map
          ? {for (final e in picked.entries) '${e.key}': '${e.value}'}
          : <String, String>{},
    );
  }

  /// Keeps (or, when [text] is blank, forgets) a thread's unsent reply.
  static Future<void> saveReplyDraft(String rootId, String text,
      {Map<String, String> picked = const {}}) async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = _replyDrafts(prefs);
    if (text.trim().isEmpty) {
      if (drafts.remove(rootId) == null) return;
    } else {
      drafts[rootId] = {
        'text': text,
        // Only the mentions still in the text matter.
        'picked': {
          for (final e in picked.entries)
            if (text.contains('@${e.key}')) e.key: e.value
        },
      };
    }
    await prefs.setString(_kReplyDrafts, jsonEncode(drafts));
  }

  static Map<String, dynamic> _replyDrafts(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_kReplyDrafts);
      return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  // ------------------------------------------------------------- emojis

  /// Offered before the reader has habits of their own.
  static const defaultEmojis = ['👍', '❤️', '😂', '🙏', '🔥', '👀'];
  static const _kEmojiCounts = 'feedback_emoji_counts';

  /// Six emojis for the quick picker: the reader's most used first (by
  /// count), topped up with the defaults.
  static Future<List<String>> quickEmojis() async {
    final prefs = await SharedPreferences.getInstance();
    final counts = _decodeCounts(prefs.getStringList(_kEmojiCounts));
    final used = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return {...used, ...defaultEmojis}.take(6).toList();
  }

  static Future<void> _rememberEmoji(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    final counts = _decodeCounts(prefs.getStringList(_kEmojiCounts));
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    await prefs.setStringList(_kEmojiCounts,
        [for (final e in counts.entries) '${e.value}\t${e.key}']);
  }

  static Map<String, int> _decodeCounts(List<String>? raw) {
    final counts = <String, int>{};
    for (final line in raw ?? const <String>[]) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final n = int.tryParse(line.substring(0, tab));
      if (n != null) counts[line.substring(tab + 1)] = n;
    }
    return counts;
  }
}
