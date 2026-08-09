import 'dart:convert';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'app_log.dart';
import 'nostr_service.dart';
import 'outbox_service.dart';

/// Thrown when a username is already registered to someone else.
class UsernameTakenException implements Exception {
  final String name;
  const UsernameTakenException(this.name);

  @override
  String toString() => '"$name" is already taken';
}

/// One profile slot in the switcher.
class ProfileSummary {
  final String id;
  final String name;
  final bool hasIdentity;
  final bool active;

  const ProfileSummary({
    required this.id,
    required this.name,
    required this.hasIdentity,
    required this.active,
  });
}

/// The user's fields as edited in the profile modal.
class Profile {
  final String name;
  final String about;
  final String picture;

  /// One link per line (website, twitter, …).
  final String links;

  const Profile(
      {this.name = '', this.about = '', this.picture = '', this.links = ''});
}

/// The optional, opt-in public profile: a locally-generated Nostr identity
/// used to share chosen highlights and comments. Everything stays private
/// and on-device until the user explicitly shares — the profile only makes
/// sharing possible.
///
/// The secret key lives in SharedPreferences on purpose: Android's standard
/// Auto Backup includes shared preferences, so restoring the app on a new
/// device (same Google account) restores the identity. Hardware-keystore
/// storage would be stronger but does not survive a device migration.
class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const _kSecret = 'profile_secret_key';
  static const _kName = 'profile_name';
  static const _kAbout = 'profile_about';
  static const _kPicture = 'profile_picture';
  static const _kLinks = 'profile_links';
  static const _kUsername = 'profile_username';
  static const _kUsernamePending = 'profile_username_pending';
  static const _kAllowedSender = 'profile_allowed_sender';

  // ---- multiple profiles ----
  // Each profile is a slot of the keys above. The first slot ('default')
  // keeps the bare key names, so existing single-profile installs need no
  // data migration; extra slots suffix their keys with '#<id>'. The active
  // slot is remembered — the last used profile survives restarts.
  static const _kProfileIds = 'profile_ids';
  static const _kActiveProfile = 'active_profile_id';

  String? _cachedActiveId;

  /// Test seam: forget the cached active slot (tests swap mock prefs).
  @visibleForTesting
  void debugResetActiveCache() {
    _cachedActiveId = null;
    _reconciledProfiles.clear();
  }

  Future<String> _activeId() async {
    final cached = _cachedActiveId;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getStringList(_kProfileIds) == null) {
      await prefs.setStringList(_kProfileIds, ['default']);
    }
    final id = prefs.getString(_kActiveProfile) ?? 'default';
    // Storage follows the profile: scoped db queries read this.
    AppDatabase.instance.activeProfile = id;
    return _cachedActiveId = id;
  }

  String _suffixed(String base, String id) =>
      id == 'default' ? base : '$base#$id';

  Future<String> _k(String base) async =>
      _suffixed(base, await _activeId());

  /// All profile slots for the switcher, in creation order.
  Future<List<ProfileSummary>> profileSummaries() async {
    final prefs = await SharedPreferences.getInstance();
    final active = await _activeId();
    final ids = prefs.getStringList(_kProfileIds) ?? ['default'];
    return [
      for (final id in ids)
        ProfileSummary(
          id: id,
          name: prefs.getString(_suffixed(_kName, id)) ?? '',
          hasIdentity: prefs.getString(_suffixed(_kSecret, id)) != null,
          active: id == active,
        ),
    ];
  }

  /// Switches the active profile; everything (identity, address, sharing)
  /// follows it.
  Future<void> switchTo(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfile, id);
    _cachedActiveId = id;
    AppDatabase.instance.activeProfile = id;
    await AppLogService.instance.info('Profile: switched to slot $id');
  }

  /// Creates an empty slot and switches to it (the opt-in screen then runs
  /// the normal create flow inside it). Returns the new slot id.
  Future<String> addProfileSlot() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kProfileIds) ?? ['default'];
    final id = 'p${DateTime.now().millisecondsSinceEpoch}';
    await prefs.setStringList(_kProfileIds, [...ids, id]);
    // Remember where we came from so the create flow can offer to bring
    // that profile's feeds and highlights along.
    await prefs.setString('previous_profile_id', await _activeId());
    await switchTo(id);
    return id;
  }

  /// The profile that was active when the current slot was created — the
  /// source of a "bring my feeds & highlights" import.
  Future<String?> get previousProfileId async =>
      (await SharedPreferences.getInstance())
          .getString('previous_profile_id');

  /// Test seam for the relay fetch behind [reconcileShares].
  @visibleForTesting
  Future<List<Map<String, dynamic>>> Function(String pubkeyHex)?
      debugFetchHighlightEvents;

  /// Brings the local Shared record in line with the relays: every
  /// published highlight event that matches a local highlight (by exact
  /// text) gets a Share row — shares made before the Shared column existed
  /// appear, with their event ids attached so quote permalinks work.
  /// Best-effort and additive; returns how many rows were created.
  /// Throttled to once per profile per app session — the relays don't
  /// need to be asked on every screen open.
  final Set<String> _reconciledProfiles = {};

  Future<int> reconcileShares() async {
    if (!await enabled) return 0;
    final slot = await _activeId();
    if (_reconciledProfiles.contains(slot)) return 0;
    _reconciledProfiles.add(slot);
    final pubkey = await publicKeyHex;
    final events = await (debugFetchHighlightEvents ??
        NostrService().fetchHighlightEvents)(pubkey);
    if (events.isEmpty) return 0;
    final db = AppDatabase.instance;
    final byText = <String, Highlight>{
      for (final h in await db.getHighlights()) h.text: h,
    };
    final recorded = <int, Share>{};
    for (final share in await db.getShares()) {
      if (share.medium == 'profile') recorded[share.highlightId] = share;
    }
    var added = 0;
    for (final event in events) {
      final text = (event['content'] as String?) ?? '';
      final highlight = byText[text];
      if (highlight == null) continue; // another device/profile's share
      final eventId = event['id'] as String?;
      final existing = recorded[highlight.id];
      if (existing != null) {
        if (existing.ref == null && eventId != null) {
          await db.setProfileShareRef(highlight.id!, eventId);
        }
        continue;
      }
      final at = event['created_at'] as int?;
      await db.insertShare(Share(
        highlightId: highlight.id!,
        medium: 'profile',
        ref: eventId,
        createdAt:
            at != null ? at * 1000 : DateTime.now().millisecondsSinceEpoch,
      ));
      added++;
    }
    if (added > 0) {
      await AppLogService.instance
          .info('Profile: reconciled $added share(s) from the relays');
    }
    return added;
  }

  /// Test seam for the metadata fetch after an import.
  @visibleForTesting
  Future<NostrProfile?> Function(String npub)? debugFetchProfile;

  /// Advanced: imports an existing identity from its nsec into a fresh
  /// slot and switches to it. Metadata (name, bio, avatar) is pulled from
  /// the relays best-effort.
  Future<void> importNsec(String nsec) async {
    final secret = NostrService.decodeBech32Key(nsec, 'nsec');
    await addProfileSlot();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _k(_kSecret), secret);
    await AppLogService.instance
        .info('Profile: imported identity ${await npub}');
    try {
      final fetched = await (debugFetchProfile ??
          NostrService().fetchProfile)(await npub);
      if (fetched != null) {
        if (fetched.name.isNotEmpty) {
          await prefs.setString(await _k(_kName), fetched.name);
        }
        if (fetched.about.isNotEmpty) {
          await prefs.setString(await _k(_kAbout), fetched.about);
        }
        if (fetched.picture.isNotEmpty) {
          await prefs.setString(await _k(_kPicture), fetched.picture);
        }
      }
    } catch (_) {
      // Offline import is fine; metadata can arrive later.
    }
  }

  /// Every reader can claim a free name@einkreader.app address (NIP-05).
  static const nip05Domain = 'einkreader.app';

  /// Username rule, mirrored by the registration server: 5–20 chars,
  /// lowercase letters, digits and underscore.
  static final usernameRule = RegExp(r'^[a-z0-9_]{5,20}$');

  /// Test seam: publishes a signed event, returns accepting-relay count.
  @visibleForTesting
  Future<int> Function(Map<String, dynamic> event)? debugPublish;

  /// Test seam for the avatar upload.
  @visibleForTesting
  http.Client? debugHttpClient;

  Future<int> _publish(Map<String, dynamic> event) =>
      (debugPublish ?? NostrService().publish)(event);

  /// Publishes, or queues in the outbox when no relay accepted (offline,
  /// relays down). Returns accepting-relay count; 0 always means "queued".
  Future<int> _publishOrQueue(
      Map<String, dynamic> event, String description) async {
    try {
      final accepted = await _publish(event);
      if (accepted > 0) return accepted;
      await OutboxService.instance.enqueueNostrEvent(event,
          description: description, error: 'No relay accepted the event');
    } catch (e) {
      await OutboxService.instance
          .enqueueNostrEvent(event, description: description, error: '$e');
    }
    return 0;
  }

  /// Whether the user opted in and has an identity (in the active slot).
  Future<bool> get enabled async =>
      (await SharedPreferences.getInstance())
          .getString(await _k(_kSecret)) !=
      null;

  /// Creates the identity (idempotent): 32 random bytes from a secure RNG.
  Future<void> createIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(await _k(_kSecret)) != null) return;
    final rng = Random.secure();
    final secret = [for (var i = 0; i < 32; i++) rng.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await prefs.setString(await _k(_kSecret), secret);
    await AppLogService.instance
        .info('Profile: created identity ${await npub}');
  }

  Future<String?> get _secret async =>
      (await SharedPreferences.getInstance()).getString(await _k(_kSecret));

  Future<String> get publicKeyHex async =>
      bip340.getPublicKey((await _secret)!);

  /// The public identity, shareable freely.
  Future<String> get npub async =>
      NostrService.bech32Encode('npub', _hexToBytes(await publicKeyHex));

  /// The SECRET key in nsec form — for the user's own backup only.
  Future<String> get nsec async =>
      NostrService.bech32Encode('nsec', _hexToBytes((await _secret)!));

  Future<Profile> profile() async {
    final prefs = await SharedPreferences.getInstance();
    return Profile(
      name: prefs.getString(await _k(_kName)) ?? '',
      about: prefs.getString(await _k(_kAbout)) ?? '',
      picture: prefs.getString(await _k(_kPicture)) ?? '',
      links: prefs.getString(await _k(_kLinks)) ?? '',
    );
  }

  /// Saves the fields locally and publishes them as kind-0 metadata
  /// (including the nip05 address once registered). Also retries a pending
  /// username registration. Returns how many relays accepted the update
  /// (0 = saved locally only).
  Future<int> saveProfile(Profile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _k(_kName), profile.name);
    await prefs.setString(await _k(_kAbout), profile.about);
    await prefs.setString(await _k(_kPicture), profile.picture);
    await prefs.setString(await _k(_kLinks), profile.links);
    await retryPendingUsername();
    final registered = await username;
    final links = profile.links
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final event = await signEvent(
      kind: 0,
      content: jsonEncode({
        if (profile.name.isNotEmpty) 'name': profile.name,
        if (profile.about.isNotEmpty) 'about': profile.about,
        if (profile.picture.isNotEmpty) 'picture': profile.picture,
        if (registered != null) 'nip05': '$registered@$nip05Domain',
        if (links.isNotEmpty) 'website': links.first,
      }),
      tags: [
        for (final link in links.skip(1)) ['r', link],
      ],
    );
    final accepted = await _publishOrQueue(event, 'Profile update');
    await AppLogService.instance
        .info('Profile: metadata published to $accepted relay(s)');
    return accepted;
  }

  /// Suggests a valid username from a display name: lowercased, invalid
  /// characters dropped, padded to the 5-char minimum, capped at 20.
  static String suggestUsername(String displayName) {
    var slug = displayName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '');
    if (slug.length < 5) slug = '${slug}reader';
    if (slug.length < 5) slug = 'reader${slug.hashCode.abs() % 10000}';
    return slug.length > 20 ? slug.substring(0, 20) : slug;
  }

  /// The claimed username (without the domain), when one is registered.
  Future<String?> get username async =>
      (await SharedPreferences.getInstance())
          .getString(await _k(_kUsername));

  /// A username chosen while offline, still waiting for its registration.
  Future<String?> get pendingUsername async =>
      (await SharedPreferences.getInstance())
          .getString(await _k(_kUsernamePending));

  /// The full address to show the user, from either state.
  Future<String?> get nip05Address async {
    final name = await username ?? await pendingUsername;
    return name == null ? null : '$name@$nip05Domain';
  }

  /// The one email address allowed to send content to name@einkreader.app
  /// (empty = the email-to-feed feature is off).
  Future<String> get allowedSender async =>
      (await SharedPreferences.getInstance())
          .getString(await _k(_kAllowedSender)) ??
      '';

  /// Stores the allowed sender and pushes it to the registration server
  /// (via a re-registration of the same name — idempotent). When offline the
  /// server update rides the pending-username retry at the next save.
  Future<void> setAllowedSender(String sender) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = sender.trim().toLowerCase();
    if (normalized == (await allowedSender)) return;
    await prefs.setString(await _k(_kAllowedSender), normalized);
    final name = await username ?? await pendingUsername;
    if (name != null) {
      try {
        await registerUsername(name);
      } on UsernameTakenException {
        // Can't happen for our own name; ignore defensively.
      }
    }
  }

  /// Authorization header for the inbox API: a fresh signed proof-of-key.
  Future<String> inboxAuthHeader() async {
    final event = await signEvent(kind: 27235, content: 'inbox');
    return 'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}';
  }

  /// Claims [name]@einkreader.app for this profile's key: POSTs the
  /// registration with a signed proof-of-ownership event. On success the
  /// name is stored; a taken name throws [UsernameTakenException]; any
  /// other failure (offline, server) stores the wish as pending — retried
  /// on the next [saveProfile].
  Future<bool> registerUsername(String name) async {
    if (!usernameRule.hasMatch(name)) {
      throw const FormatException(
          'Username must be 5–20 characters: a–z, 0–9 and _ only');
    }
    final prefs = await SharedPreferences.getInstance();
    final event = await signEvent(kind: 27235, content: name);
    final sender = await allowedSender;
    try {
      final response = await (debugHttpClient ?? http.Client())
          .post(
            Uri.https(nip05Domain, '/api/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'pubkey': await publicKeyHex,
              'event': event,
              if (sender.isNotEmpty) 'sender': sender,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 409) {
        throw UsernameTakenException(name);
      }
      if (response.statusCode != 200) {
        throw Exception('Registration failed '
            '(HTTP ${response.statusCode}: ${response.body})');
      }
      await prefs.setString(await _k(_kUsername), name);
      await prefs.remove(await _k(_kUsernamePending));
      await AppLogService.instance
          .info('Profile: registered $name@$nip05Domain');
      return true;
    } on UsernameTakenException {
      rethrow;
    } catch (e) {
      await prefs.setString(await _k(_kUsernamePending), name);
      await AppLogService.instance
          .warn('Profile: username registration pending ($name): $e');
      return false;
    }
  }

  /// Retries a pending registration; quiet no-op when nothing is pending
  /// or the name got taken meanwhile (the user picks another in the modal).
  Future<void> retryPendingUsername() async {
    final pending = await pendingUsername;
    if (pending == null) return;
    try {
      await registerUsername(pending);
    } on UsernameTakenException {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(await _k(_kUsernamePending));
    }
  }

  /// Media host for avatars (Blossom protocol, BUD-02).
  static const blossomServer = 'https://blossom.primal.net';

  /// Uploads an avatar image and returns its public URL. The request is
  /// authorized with a signed kind-24242 event carrying the blob's sha256,
  /// per the Blossom spec.
  Future<String> uploadAvatar(Uint8List bytes,
      {String mime = 'image/jpeg'}) async {
    final hash = sha256.convert(bytes).toString();
    final expiration =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10 * 60;
    final auth = await signEvent(
      kind: 24242,
      content: 'Upload avatar',
      tags: [
        ['t', 'upload'],
        ['x', hash],
        ['expiration', '$expiration'],
      ],
    );
    final response = await (debugHttpClient ?? http.Client())
        .put(
          Uri.parse('$blossomServer/upload'),
          headers: {
            'Authorization':
                'Nostr ${base64Encode(utf8.encode(jsonEncode(auth)))}',
            'Content-Type': mime,
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'Avatar upload failed (HTTP ${response.statusCode})');
    }
    final url =
        (jsonDecode(response.body) as Map<String, dynamic>)['url'] as String?;
    if (url == null) {
      throw Exception('Avatar upload returned no URL');
    }
    await AppLogService.instance.info('Profile: avatar uploaded to $url');
    return url;
  }

  /// Publishes a highlight (NIP-84 kind 9802) with an optional comment.
  /// Returns the accepting-relay count (0 = queued in the outbox) and the
  /// event id — the id is what quote permalinks point at, valid either way
  /// since queued events re-send verbatim.
  Future<({int accepted, String eventId})> publishHighlight(
      Article article, Highlight highlight) async {
    final event = await signEvent(
      kind: 9802,
      content: highlight.text,
      tags: [
        if (article.url != null) ['r', article.url!],
        ['title', article.displayTitle],
        if ((highlight.comment ?? '').isNotEmpty)
          ['comment', highlight.comment!],
        // NIP-89 client tag: the standard way to mark the publishing app.
        ['client', 'einkreader'],
      ],
    );
    final preview = highlight.text.length > 60
        ? '${highlight.text.substring(0, 60)}…'
        : highlight.text;
    final accepted = await _publishOrQueue(event, 'Highlight: "$preview"');
    await AppLogService.instance
        .info('Profile: highlight published to $accepted relay(s)');
    return (accepted: accepted, eventId: event['id'] as String);
  }

  /// The public permalink for a highlight shared to the profile.
  Future<String?> quoteLink(String eventId) async {
    final name = await username ?? await pendingUsername;
    if (name == null) return null;
    return 'https://$nip05Domain/$name/q/${eventId.substring(0, 12)}';
  }

  /// One-tap email share (Email plugin): the server sends from
  /// name@einkreader.app with Reply-To the user's own address; delivery is
  /// real, not a mailto handoff. Throws on failure.
  Future<void> sendShareEmail({
    required String to,
    required String subject,
    required String text,
  }) async {
    final event = await signEvent(kind: 27235, content: 'send-share');
    final response = await (debugHttpClient ?? http.Client())
        .post(
          Uri.https(nip05Domain, '/api/send-share'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization':
                'Nostr ${base64Encode(utf8.encode(jsonEncode(event)))}',
          },
          body: jsonEncode({'to': to, 'subject': subject, 'text': text}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Send failed (HTTP ${response.statusCode}: '
          '${response.body})');
    }
    await AppLogService.instance.info('Profile: share emailed to $to');
  }

  /// Builds and Schnorr-signs a Nostr event (NIP-01).
  @visibleForTesting
  Future<Map<String, dynamic>> signEvent({
    required int kind,
    required String content,
    List<List<String>> tags = const [],
  }) async {
    final secret = (await _secret)!;
    final pubkey = bip340.getPublicKey(secret);
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final serialized =
        jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    final id = sha256.convert(utf8.encode(serialized)).toString();
    final rng = Random.secure();
    final aux = [for (var i = 0; i < 32; i++) rng.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': bip340.sign(secret, id, aux),
    };
  }

  static List<int> _hexToBytes(String hex) => [
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ];
}
