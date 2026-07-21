import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  static const defaultRelays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
  ];

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

  /// Sends one REQ to every relay and merges events until EOSE or timeout.
  Future<List<Map<String, dynamic>>> _query(Map<String, dynamic> filter,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final results = await Future.wait(
        (await relays()).map((relay) => _queryRelay(relay, filter, timeout)));
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
