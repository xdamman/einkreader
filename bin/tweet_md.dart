// Command-line tool to fetch a tweet / native X Article and print it as the
// Markdown the reader would render — handy for iterating on the conversion in
// lib/services/twitter_markdown.dart.
//
//   dart run bin/tweet_md.dart <tweet-url-or-id> [--json] [--no-embeds] [--login]
//
// Examples:
//   dart run bin/tweet_md.dart https://x.com/nickgrossman/status/2070181707613937866
//   dart run bin/tweet_md.dart https://x.com/albertwenger/status/2070189404207853809
//   dart run bin/tweet_md.dart 2070181707613937866 --json
//
// On first use it walks you through a one-time OAuth login and caches the
// tokens in ~/.einkreader/env. The X OAuth client id is hardcoded below; no
// client secret is needed (it is a public PKCE client).
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:einkreader/services/twitter_markdown.dart';
import 'package:http/http.dart' as http;

const _clientId = 'cXRXOEdnZlg1cmVHMy04MmtPbXM6MTpjaQ';
const _redirectUri = 'einkreader://callback';
const _authorizeUrl = 'https://x.com/i/oauth2/authorize';
const _tokenUrl = 'https://api.x.com/2/oauth2/token';
const _apiBase = 'https://api.x.com/2';
const _scopes = 'tweet.read users.read offline.access';

const _tweetFields =
    'created_at,entities,author_id,note_tweet,referenced_tweets,article';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final flags = args.where((a) => a.startsWith('-')).toSet();
  final dumpJson = flags.contains('--json');
  final withEmbeds = !flags.contains('--no-embeds');
  final forceLogin = flags.contains('--login');

  if (positional.isEmpty && !forceLogin) {
    stderr.writeln('Usage: dart run bin/tweet_md.dart <tweet-url-or-id> '
        '[--json] [--no-embeds] [--login]');
    exitCode = 64;
    return;
  }

  final token = await _accessToken(forceLogin: forceLogin);
  if (positional.isEmpty) {
    stderr.writeln('Logged in. Pass a tweet URL or id to fetch.');
    return;
  }

  final id = _tweetId(positional.first);
  if (id == null) {
    stderr.writeln('Could not find a tweet id in "${positional.first}".');
    exitCode = 64;
    return;
  }

  final response = await _getTweet(id, token);
  if (dumpJson) {
    print(const JsonEncoder.withIndent('  ').convert(response));
    return;
  }

  print(await _toMarkdown(response, token, withEmbeds: withEmbeds));
}

// --------------------------------------------------------------- conversion

/// Builds the Markdown for [response] (a `GET /2/tweets/:id` payload),
/// fetching the quoted article / cover image / embedded posts as needed.
Future<String> _toMarkdown(Map<String, dynamic> response, String token,
    {required bool withEmbeds}) async {
  final tweet = response['data'] as Map<String, dynamic>;
  final users = _usersById(response);
  final media = _mediaUrlsById(response);

  // The tweet is itself a native article (or note): render it directly.
  if (isLongFormTweet(tweet)) {
    return _renderArticle(tweet, token, users, media, withEmbeds: withEmbeds);
  }

  // The tweet quotes / links another post: inline it when it is an article.
  final body = noteOf(tweet) ?? tweet;
  final quotedId = linkedTweetId(tweet, body);
  if (quotedId != null && quotedId != tweet['id']) {
    final quoted = await _getTweet(quotedId, token);
    final quotedTweet = quoted['data'] as Map<String, dynamic>;
    if (isLongFormTweet(quotedTweet)) {
      final article = _renderArticle(
          quotedTweet, token, _usersById(quoted), _mediaUrlsById(quoted),
          withEmbeds: withEmbeds);
      return '${expandTweetUrls(tweet)}\n\n---\n\n${await article}';
    }
  }
  return expandTweetUrls(tweet);
}

Future<String> _renderArticle(
  Map<String, dynamic> tweet,
  String token,
  Map<String, Map<String, dynamic>> users,
  Map<String, String> media, {
  required bool withEmbeds,
}) async {
  final embeds = <String, String>{};
  final article = articleOf(tweet);
  if (withEmbeds && article != null) {
    final ids = ((article['entities']?['tweets'] as List?) ?? const [])
        .map((e) => e['id'] as String?)
        .whereType<String>();
    for (final id in ids) {
      try {
        final json = await _getTweet(id, token);
        final embeddedTweet = json['data'] as Map<String, dynamic>;
        final author = _usersById(json)[embeddedTweet['author_id']];
        embeds[id] = postBlockquote(
          tweetBodyMarkdown(embeddedTweet),
          authorName: author?['name'] as String?,
          authorUsername: author?['username'] as String?,
        );
      } catch (e) {
        stderr.writeln('Skipping embedded post $id: $e');
      }
    }
  }
  return tweetBodyMarkdown(tweet, mediaUrls: media, embeddedPosts: embeds);
}

Map<String, Map<String, dynamic>> _usersById(Map<String, dynamic> json) {
  final out = <String, Map<String, dynamic>>{};
  for (final u in (json['includes']?['users'] as List?) ?? const []) {
    out[u['id'] as String] = u as Map<String, dynamic>;
  }
  return out;
}

/// media_key -> best image URL, from the response `includes.media`.
Map<String, String> _mediaUrlsById(Map<String, dynamic> json) {
  final out = <String, String>{};
  for (final m in (json['includes']?['media'] as List?) ?? const []) {
    final key = m['media_key'] as String?;
    final url = (m['url'] ?? m['preview_image_url']) as String?;
    if (key != null && url != null) out[key] = url;
  }
  return out;
}

// ------------------------------------------------------------------- api

String? _tweetId(String input) {
  final status = RegExp(r'status/(\d+)').firstMatch(input);
  if (status != null) return status.group(1);
  if (RegExp(r'^\d+$').hasMatch(input.trim())) return input.trim();
  return null;
}

Future<Map<String, dynamic>> _getTweet(String id, String token) async {
  final uri = Uri.parse('$_apiBase/tweets/$id').replace(queryParameters: {
    'tweet.fields': _tweetFields,
    'expansions': 'author_id,referenced_tweets.id,attachments.media_keys',
    'user.fields': 'name,username',
    'media.fields': 'url,preview_image_url,type',
  });
  final response =
      await http.get(uri, headers: {'Authorization': 'Bearer $token'});
  if (response.statusCode != 200) {
    throw Exception('GET /tweets/$id -> ${response.statusCode}: '
        '${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

// ---------------------------------------------------------------- oauth

Future<String> _accessToken({required bool forceLogin}) async {
  final env = _loadEnv();
  if (!forceLogin && env['TWITTER_REFRESH_TOKEN'] != null) {
    final expiresAt = int.tryParse(env['TWITTER_EXPIRES_AT'] ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (env['TWITTER_ACCESS_TOKEN'] != null && now < expiresAt - 60000) {
      return env['TWITTER_ACCESS_TOKEN']!;
    }
    try {
      return await _refresh(env['TWITTER_REFRESH_TOKEN']!);
    } catch (e) {
      stderr.writeln('Token refresh failed ($e); logging in again.');
    }
  }
  return _login();
}

Future<String> _login() async {
  final verifier = _randomString(64);
  final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
  final state = _randomString(24);
  final authUrl = Uri.parse(_authorizeUrl).replace(queryParameters: {
    'response_type': 'code',
    'client_id': _clientId,
    'redirect_uri': _redirectUri,
    'scope': _scopes,
    'state': state,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
  });

  stdout.writeln('\n1. Authorize in the browser window that just opened (or '
      'open the URL below).');
  stdout.writeln('2. Your browser will try to go to $_redirectUri…?code=… and '
      'fail to load — that is expected.');
  stdout.writeln('3. Copy that whole URL from the address bar and paste it '
      'here (or just the code).\n');
  stdout.writeln(authUrl);
  _tryOpen(authUrl.toString());
  stdout.write('\nPasted URL or code: ');
  final input = stdin.readLineSync()?.trim() ?? '';
  final code = _codeFrom(input);
  if (code == null) throw Exception('No code found in the pasted value.');

  final response = await http.post(Uri.parse(_tokenUrl), headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
  }, body: {
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': _redirectUri,
    'client_id': _clientId,
    'code_verifier': verifier,
  });
  if (response.statusCode != 200) {
    throw Exception('Token exchange failed: ${response.body}');
  }
  return _storeTokens(jsonDecode(response.body) as Map<String, dynamic>);
}

Future<String> _refresh(String refreshToken) async {
  final response = await http.post(Uri.parse(_tokenUrl), headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
  }, body: {
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': _clientId,
  });
  if (response.statusCode != 200) {
    throw Exception('refresh -> ${response.statusCode}: ${response.body}');
  }
  return _storeTokens(jsonDecode(response.body) as Map<String, dynamic>);
}

String _storeTokens(Map<String, dynamic> json) {
  final env = _loadEnv();
  final access = json['access_token'] as String;
  env['TWITTER_ACCESS_TOKEN'] = access;
  if (json['refresh_token'] != null) {
    env['TWITTER_REFRESH_TOKEN'] = json['refresh_token'] as String;
  }
  final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 7200;
  env['TWITTER_EXPIRES_AT'] =
      '${DateTime.now().millisecondsSinceEpoch + expiresIn * 1000}';
  _saveEnv(env);
  return access;
}

String? _codeFrom(String input) {
  final uri = Uri.tryParse(input);
  final fromQuery = uri?.queryParameters['code'];
  if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
  return input.isEmpty ? null : input;
}

void _tryOpen(String url) {
  try {
    if (Platform.isMacOS) {
      Process.runSync('open', [url]);
    } else if (Platform.isLinux) {
      Process.runSync('xdg-open', [url]);
    }
  } catch (_) {
    // Best effort; the URL is printed above regardless.
  }
}

// --------------------------------------------------------------- env file

File _envFile() => File('${Platform.environment['HOME']}/.einkreader/env');

Map<String, String> _loadEnv() {
  final file = _envFile();
  if (!file.existsSync()) return {};
  final env = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    env[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
  }
  return env;
}

void _saveEnv(Map<String, String> env) {
  final file = _envFile();
  file.parent.createSync(recursive: true);
  final body = env.entries.map((e) => '${e.key}=${e.value}').join('\n');
  file.writeAsStringSync('$body\n');
}

String _randomString(int length) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = Random.secure();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)])
      .join();
}
