import 'dart:convert';
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Whether the user opted in and has an identity.
  Future<bool> get enabled async =>
      (await SharedPreferences.getInstance()).getString(_kSecret) != null;

  /// Creates the identity (idempotent): 32 random bytes from a secure RNG.
  Future<void> createIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kSecret) != null) return;
    final rng = Random.secure();
    final secret = [for (var i = 0; i < 32; i++) rng.nextInt(256)]
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await prefs.setString(_kSecret, secret);
    await AppLogService.instance
        .info('Profile: created identity ${await npub}');
  }

  Future<String?> get _secret async =>
      (await SharedPreferences.getInstance()).getString(_kSecret);

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
      name: prefs.getString(_kName) ?? '',
      about: prefs.getString(_kAbout) ?? '',
      picture: prefs.getString(_kPicture) ?? '',
      links: prefs.getString(_kLinks) ?? '',
    );
  }

  /// Saves the fields locally and publishes them as kind-0 metadata
  /// (including the nip05 address once registered). Also retries a pending
  /// username registration. Returns how many relays accepted the update
  /// (0 = saved locally only).
  Future<int> saveProfile(Profile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, profile.name);
    await prefs.setString(_kAbout, profile.about);
    await prefs.setString(_kPicture, profile.picture);
    await prefs.setString(_kLinks, profile.links);
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
      (await SharedPreferences.getInstance()).getString(_kUsername);

  /// A username chosen while offline, still waiting for its registration.
  Future<String?> get pendingUsername async =>
      (await SharedPreferences.getInstance())
          .getString(_kUsernamePending);

  /// The full address to show the user, from either state.
  Future<String?> get nip05Address async {
    final name = await username ?? await pendingUsername;
    return name == null ? null : '$name@$nip05Domain';
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
    try {
      final response = await (debugHttpClient ?? http.Client())
          .post(
            Uri.https(nip05Domain, '/api/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'pubkey': await publicKeyHex,
              'event': event,
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
      await prefs.setString(_kUsername, name);
      await prefs.remove(_kUsernamePending);
      await AppLogService.instance
          .info('Profile: registered $name@$nip05Domain');
      return true;
    } on UsernameTakenException {
      rethrow;
    } catch (e) {
      await prefs.setString(_kUsernamePending, name);
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
      await prefs.remove(_kUsernamePending);
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
  /// Returns how many relays accepted it.
  Future<int> publishHighlight(Article article, Highlight highlight) async {
    final event = await signEvent(
      kind: 9802,
      content: highlight.text,
      tags: [
        if (article.url != null) ['r', article.url!],
        ['title', article.displayTitle],
        if ((highlight.comment ?? '').isNotEmpty)
          ['comment', highlight.comment!],
      ],
    );
    final preview = highlight.text.length > 60
        ? '${highlight.text.substring(0, 60)}…'
        : highlight.text;
    final accepted = await _publishOrQueue(event, 'Highlight: "$preview"');
    await AppLogService.instance
        .info('Profile: highlight published to $accepted relay(s)');
    return accepted;
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
