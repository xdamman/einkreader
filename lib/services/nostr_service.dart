import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A profile found on Nostr (kind-0 metadata).
class NostrProfile {
  final String pubkey; // hex
  final String name;
  final String about;
  final String picture;

  const NostrProfile({
    required this.pubkey,
    this.name = '',
    this.about = '',
    this.picture = '',
  });
}

/// A long-form article (kind 30023, NIP-23): content is already Markdown.
class NostrLongRead {
  final String id;
  final String title;
  final String? summary;
  final String contentMarkdown;
  final DateTime? publishedAt;

  const NostrLongRead({
    required this.id,
    required this.title,
    this.summary,
    required this.contentMarkdown,
    this.publishedAt,
  });
}

/// A note or URL referenced from the user's Nostr bookmarks or likes.
class NostrItem {
  /// Event id (hex) or the URL itself for plain "r" bookmark tags.
  final String id;
  final String content;
  final String? authorPubkey;
  final DateTime? createdAt;
  final String? articleUrl;

  const NostrItem({
    required this.id,
    required this.content,
    this.authorPubkey,
    this.createdAt,
    this.articleUrl,
  });
}

/// Read-only Nostr client: given an npub it loads the public bookmark list
/// (kind 10003, NIP-51) and recent reactions (kind 7, NIP-25) from a set of
/// public relays. No private key is ever needed.
class NostrService {
  NostrService({http.Client? client}) : _http = client ?? http.Client();

  /// For NIP-05 (name@domain) lookups.
  final http.Client _http;

  static const defaultRelays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
  ];

  /// Relays known to implement NIP-50 full-text search (used only for
  /// profile search, independent of the user's relay list).
  static const searchRelays = ['wss://relay.nostr.band'];

  /// Preference holding the user's relay list (Settings → Nostr relays).
  /// Absent or empty falls back to [defaultRelays].
  static const relaysPrefKey = 'nostr_relays';

  /// The relays currently in use.
  static Future<List<String>> relays() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(relaysPrefKey);
    return (stored == null || stored.isEmpty) ? defaultRelays : stored;
  }

  static Future<void> saveRelays(List<String> relays) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(relaysPrefKey, relays);
  }

  /// True when [relay] answers a WebSocket handshake within [timeout].
  static Future<bool> checkRelay(String relay,
      {Duration timeout = const Duration(seconds: 5)}) async {
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(relay));
      await channel.ready.timeout(timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
  }

  static final _urlRegExp = RegExp(r'https?://[^\s<>"\)\]]+');

  static const _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  /// Encodes 32 [bytes] as a bech32 string with the given [hrp]
  /// ("npub" / "nsec"), per NIP-19.
  static String bech32Encode(String hrp, List<int> bytes) {
    // 8-bit bytes to 5-bit groups.
    var acc = 0;
    var bits = 0;
    final data = <int>[];
    for (final byte in bytes) {
      acc = (acc << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        data.add((acc >> bits) & 31);
      }
    }
    if (bits > 0) data.add((acc << (5 - bits)) & 31);

    List<int> hrpExpand() => [
          for (final c in hrp.codeUnits) c >> 5,
          0,
          for (final c in hrp.codeUnits) c & 31,
        ];
    int polymod(List<int> values) {
      const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
      var chk = 1;
      for (final v in values) {
        final b = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (var i = 0; i < 5; i++) {
          if ((b >> i) & 1 == 1) chk ^= gen[i];
        }
      }
      return chk;
    }

    final checksum = polymod([...hrpExpand(), ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
    final full = [
      ...data,
      for (var i = 0; i < 6; i++) (checksum >> (5 * (5 - i))) & 31,
    ];
    return '${hrp}1${full.map((v) => _bech32Charset[v]).join()}';
  }

  /// Decodes an npub1... string into a hex pubkey (bech32, NIP-19).
  static String decodeNpub(String npub) {
    final input = npub.trim().toLowerCase();
    if (!input.startsWith('npub1')) {
      throw const FormatException('Expected an npub1... key');
    }
    const charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
    final dataPart = input.substring(5); // after "npub1"
    final values = <int>[];
    for (final char in dataPart.split('')) {
      final v = charset.indexOf(char);
      if (v == -1) throw const FormatException('Invalid bech32 character');
      values.add(v);
    }
    if (values.length < 6) throw const FormatException('npub too short');
    final data = values.sublist(0, values.length - 6); // drop checksum
    // Convert 5-bit groups to 8-bit bytes.
    var acc = 0;
    var bits = 0;
    final bytes = <int>[];
    for (final value in data) {
      acc = (acc << 5) | value;
      bits += 5;
      while (bits >= 8) {
        bits -= 8;
        bytes.add((acc >> bits) & 0xff);
      }
    }
    if (bytes.length != 32) {
      throw const FormatException('npub does not contain a 32-byte key');
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Loads the user's bookmarked notes and URLs (kind 10003).
  Future<List<NostrItem>> fetchBookmarks(String npub) async {
    final pubkey = decodeNpub(npub);
    final lists = await _query({
      'kinds': [10003],
      'authors': [pubkey],
      'limit': 1,
    });
    if (lists.isEmpty) return [];
    lists.sort((a, b) =>
        (b['created_at'] as int? ?? 0).compareTo(a['created_at'] as int? ?? 0));
    final tags = (lists.first['tags'] as List?) ?? const [];

    final eventIds = <String>[];
    final items = <NostrItem>[];
    for (final tag in tags) {
      if (tag is! List || tag.length < 2) continue;
      if (tag[0] == 'e') eventIds.add(tag[1] as String);
      if (tag[0] == 'r') {
        final url = tag[1] as String;
        items.add(NostrItem(id: url, content: url, articleUrl: url));
      }
    }
    items.addAll(await _fetchNotes(eventIds));
    return items;
  }

  /// Loads the notes the user recently reacted to (kind 7 likes).
  Future<List<NostrItem>> fetchLikes(String npub) async {
    final pubkey = decodeNpub(npub);
    final reactions = await _query({
      'kinds': [7],
      'authors': [pubkey],
      'limit': 100,
    });
    final eventIds = <String>{};
    for (final reaction in reactions) {
      // Per NIP-25 the last "e" tag is the reacted-to event.
      final tags = (reaction['tags'] as List?) ?? const [];
      String? target;
      for (final tag in tags) {
        if (tag is List && tag.length >= 2 && tag[0] == 'e') {
          target = tag[1] as String;
        }
      }
      if (target != null) eventIds.add(target);
    }
    return _fetchNotes(eventIds.take(50).toList());
  }

  Future<List<NostrItem>> _fetchNotes(List<String> eventIds) async {
    if (eventIds.isEmpty) return [];
    final events = await _query({'ids': eventIds});
    final seen = <String>{};
    final items = <NostrItem>[];
    for (final event in events) {
      final id = event['id'] as String?;
      if (id == null || !seen.add(id)) continue;
      final content = (event['content'] as String?) ?? '';
      final createdAt = event['created_at'] as int?;
      items.add(NostrItem(
        id: id,
        content: content,
        authorPubkey: event['pubkey'] as String?,
        createdAt: createdAt != null
            ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
            : null,
        articleUrl: firstUrl(content),
      ));
    }
    return items;
  }

  /// Encodes a hex pubkey as npub1… (NIP-19).
  static String npubEncode(String hexPubkey) => bech32Encode('npub', [
        for (var i = 0; i < hexPubkey.length; i += 2)
          int.parse(hexPubkey.substring(i, i + 2), radix: 16)
      ]);

  static NostrProfile _profileFromEvent(Map<String, dynamic> event) {
    Map<String, dynamic> meta;
    try {
      meta = jsonDecode((event['content'] as String?) ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {
      meta = const {};
    }
    return NostrProfile(
      pubkey: (event['pubkey'] as String?) ?? '',
      name: (meta['display_name'] as String?)?.trim().isNotEmpty == true
          ? (meta['display_name'] as String).trim()
          : ((meta['name'] as String?) ?? '').trim(),
      about: ((meta['about'] as String?) ?? '').trim(),
      picture: ((meta['picture'] as String?) ?? '').trim(),
    );
  }

  /// Loads a profile's kind-0 metadata; null when none is found.
  Future<NostrProfile?> fetchProfile(String npub) async {
    final pubkey = decodeNpub(npub);
    final events = await _query({
      'kinds': [0],
      'authors': [pubkey],
      'limit': 1,
    });
    if (events.isEmpty) return null;
    events.sort((a, b) =>
        (b['created_at'] as int? ?? 0).compareTo(a['created_at'] as int? ?? 0));
    return _profileFromEvent(events.first);
  }

  /// A followed profile's recent short notes (kind 1), replies excluded.
  Future<List<NostrItem>> fetchAuthorNotes(String npub) async {
    final pubkey = decodeNpub(npub);
    final events = await _query({
      'kinds': [1],
      'authors': [pubkey],
      'limit': 50,
    });
    final items = <NostrItem>[];
    for (final event in events) {
      final tags = (event['tags'] as List?) ?? const [];
      final isReply = tags.any(
          (tag) => tag is List && tag.isNotEmpty && tag[0] == 'e');
      if (isReply) continue;
      final content = (event['content'] as String?) ?? '';
      if (content.trim().isEmpty) continue;
      final createdAt = event['created_at'] as int?;
      items.add(NostrItem(
        id: (event['id'] as String?) ?? '',
        content: content,
        authorPubkey: event['pubkey'] as String?,
        createdAt: createdAt != null
            ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
            : null,
        articleUrl: firstUrl(content),
      ));
    }
    return items;
  }

  /// A followed profile's long-form articles (kind 30023): ready-made
  /// Markdown, no page download needed.
  Future<List<NostrLongRead>> fetchLongReads(String npub) async {
    final pubkey = decodeNpub(npub);
    final events = await _query({
      'kinds': [30023],
      'authors': [pubkey],
      'limit': 30,
    });
    String? tagValue(List tags, String name) {
      for (final tag in tags) {
        if (tag is List && tag.length >= 2 && tag[0] == name) {
          return tag[1] as String?;
        }
      }
      return null;
    }

    final reads = <NostrLongRead>[];
    for (final event in events) {
      final content = (event['content'] as String?) ?? '';
      if (content.trim().isEmpty) continue;
      final tags = (event['tags'] as List?) ?? const [];
      final publishedAt = int.tryParse(tagValue(tags, 'published_at') ?? '') ??
          event['created_at'] as int?;
      reads.add(NostrLongRead(
        id: (event['id'] as String?) ?? '',
        title: tagValue(tags, 'title') ?? 'Untitled',
        summary: tagValue(tags, 'summary'),
        contentMarkdown: content,
        publishedAt: publishedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(publishedAt * 1000)
            : null,
      ));
    }
    return reads;
  }

  /// Full-text profile search (NIP-50) on the search relays. Returns the
  /// latest kind-0 per matching pubkey.
  Future<List<NostrProfile>> searchProfiles(String query) async {
    final events = await _query(
      {
        'kinds': [0],
        'search': query,
        'limit': 10,
      },
      onRelays: searchRelays,
    );
    // Latest metadata per pubkey.
    final byPubkey = <String, Map<String, dynamic>>{};
    for (final event in events) {
      final pubkey = event['pubkey'] as String?;
      if (pubkey == null) continue;
      final existing = byPubkey[pubkey];
      if (existing == null ||
          (event['created_at'] as int? ?? 0) >
              (existing['created_at'] as int? ?? 0)) {
        byPubkey[pubkey] = event;
      }
    }
    return byPubkey.values.map(_profileFromEvent).toList();
  }

  /// Resolves a NIP-05 identifier (name@domain) to a hex pubkey via the
  /// domain's /.well-known/nostr.json. Throws when it can't be resolved.
  Future<String> resolveNip05(String identifier) async {
    final parts = identifier.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      throw const FormatException('Expected name@domain');
    }
    final name = parts[0].toLowerCase();
    final uri = Uri.https(parts[1], '/.well-known/nostr.json', {'name': name});
    final response =
        await _http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('NIP-05 lookup failed (HTTP ${response.statusCode})');
    }
    final names = (jsonDecode(response.body)
        as Map<String, dynamic>)['names'] as Map<String, dynamic>?;
    final pubkey = names?[name] as String?;
    if (pubkey == null) {
      throw Exception('No "$name" at ${parts[1]}');
    }
    return pubkey;
  }

  /// Returns the first http(s) URL in a note, skipping bare media files.
  static String? firstUrl(String content) {
    for (final match in _urlRegExp.allMatches(content)) {
      final url = match.group(0)!;
      final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
      if (RegExp(r'\.(jpg|jpeg|png|gif|webp|mp4|mov|webm)$').hasMatch(path)) {
        continue;
      }
      return url;
    }
    return null;
  }

  /// Sends one REQ to every relay (or [onRelays]) and merges events until
  /// EOSE or timeout.
  Future<List<Map<String, dynamic>>> _query(Map<String, dynamic> filter,
      {Duration timeout = const Duration(seconds: 8),
      List<String>? onRelays}) async {
    final results = await Future.wait((onRelays ?? await relays())
        .map((relay) => _queryRelay(relay, filter, timeout)));
    final merged = <String, Map<String, dynamic>>{};
    for (final events in results) {
      for (final event in events) {
        final id = event['id'] as String?;
        if (id != null) merged[id] = event;
      }
    }
    return merged.values.toList();
  }

  Future<List<Map<String, dynamic>>> _queryRelay(
      String relay, Map<String, dynamic> filter, Duration timeout) async {
    final events = <Map<String, dynamic>>[];
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(relay));
      await channel.ready.timeout(timeout);
      const subId = 'einkreader';
      channel.sink.add(jsonEncode(['REQ', subId, filter]));

      final done = Completer<void>();
      final sub = channel.stream.listen((message) {
        try {
          final decoded = jsonDecode(message as String) as List;
          if (decoded[0] == 'EVENT' && decoded.length >= 3) {
            events.add(decoded[2] as Map<String, dynamic>);
          } else if (decoded[0] == 'EOSE' || decoded[0] == 'CLOSED') {
            if (!done.isCompleted) done.complete();
          }
        } catch (_) {/* ignore malformed relay messages */}
      }, onError: (Object _) {
        if (!done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });

      await done.future.timeout(timeout, onTimeout: () {});
      await sub.cancel();
    } catch (_) {
      // Relay unreachable; other relays may still answer.
    } finally {
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
    return events;
  }

  /// Sends an already-signed event to every default relay and returns how
  /// many accepted it. Signing lives in ProfileService — this service never
  /// touches keys.
  Future<int> publish(Map<String, dynamic> event,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final results = await Future.wait(
        (await relays()).map((relay) => _publishTo(relay, event, timeout)));
    return results.where((ok) => ok).length;
  }

  Future<bool> _publishTo(
      String relay, Map<String, dynamic> event, Duration timeout) async {
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(relay));
      await channel.ready.timeout(timeout);
      final accepted = Completer<bool>();
      final sub = channel.stream.listen((message) {
        try {
          final decoded = jsonDecode(message as String) as List;
          if (decoded[0] == 'OK' &&
              decoded[1] == event['id'] &&
              !accepted.isCompleted) {
            accepted.complete(decoded[2] == true);
          }
        } catch (_) {/* ignore malformed relay messages */}
      }, onError: (Object _) {
        if (!accepted.isCompleted) accepted.complete(false);
      }, onDone: () {
        if (!accepted.isCompleted) accepted.complete(false);
      });
      channel.sink.add(jsonEncode(['EVENT', event]));
      final ok =
          await accepted.future.timeout(timeout, onTimeout: () => false);
      await sub.cancel();
      return ok;
    } catch (_) {
      return false;
    } finally {
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
  }
}
