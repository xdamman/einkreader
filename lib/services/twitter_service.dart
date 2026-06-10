import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// A tweet reduced to what the reader needs.
class TweetItem {
  final String id;
  final String text;
  final String? authorName;
  final String? authorUsername;
  final DateTime? createdAt;

  /// First non-twitter URL in the tweet, used to fetch the full article.
  final String? articleUrl;

  const TweetItem({
    required this.id,
    required this.text,
    this.authorName,
    this.authorUsername,
    this.createdAt,
    this.articleUrl,
  });

  String get tweetUrl => 'https://x.com/${authorUsername ?? 'i'}/status/$id';
}

/// Twitter / X API v2 client using OAuth 2.0 with PKCE.
///
/// The user supplies their own OAuth 2.0 Client ID (created for free at
/// developer.x.com) in the Settings screen; no client secret is required for
/// a public PKCE client.
class TwitterService {
  static const callbackScheme = 'einkreader';
  static const _redirectUri = 'einkreader://callback';
  static const _authorizeUrl = 'https://x.com/i/oauth2/authorize';
  static const _tokenUrl = 'https://api.x.com/2/oauth2/token';
  static const _apiBase = 'https://api.x.com/2';
  static const _scopes =
      'tweet.read users.read bookmark.read like.read offline.access';

  static const _storage = FlutterSecureStorage();
  static const _kAccessToken = 'twitter_access_token';
  static const _kRefreshToken = 'twitter_refresh_token';
  static const _kExpiresAt = 'twitter_expires_at';
  static const _kClientId = 'twitter_client_id';
  static const _kUserId = 'twitter_user_id';
  static const _kUsername = 'twitter_username';

  Future<bool> get isConnected async =>
      (await _storage.read(key: _kRefreshToken)) != null;

  Future<String?> get username async => _storage.read(key: _kUsername);

  Future<void> disconnect() async {
    for (final key in [
      _kAccessToken, _kRefreshToken, _kExpiresAt, _kUserId, _kUsername,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// Runs the full OAuth 2.0 PKCE flow in a browser sheet and stores the
  /// resulting tokens. Returns the authenticated username.
  Future<String> connect(String clientId) async {
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(
            sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(24);

    final authUrl = Uri.parse(_authorizeUrl).replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': _redirectUri,
      'scope': _scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    final result = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(), callbackUrlScheme: callbackScheme);
    final params = Uri.parse(result).queryParameters;
    if (params['state'] != state) {
      throw Exception('OAuth state mismatch');
    }
    final code = params['code'];
    if (code == null) {
      throw Exception(params['error_description'] ??
          params['error'] ??
          'Authorization was denied');
    }

    final tokenResponse = await http.post(Uri.parse(_tokenUrl), headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    }, body: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': _redirectUri,
      'client_id': clientId,
      'code_verifier': verifier,
    });
    if (tokenResponse.statusCode != 200) {
      throw Exception('Token exchange failed: ${tokenResponse.body}');
    }
    await _storeTokens(jsonDecode(tokenResponse.body));
    await _storage.write(key: _kClientId, value: clientId);

    final me = await _get('/users/me');
    final user = me['data'] as Map<String, dynamic>;
    await _storage.write(key: _kUserId, value: user['id'] as String);
    await _storage.write(key: _kUsername, value: user['username'] as String);
    return user['username'] as String;
  }

  Future<List<TweetItem>> fetchBookmarks() => _fetchTimeline('bookmarks');

  Future<List<TweetItem>> fetchLikes() => _fetchTimeline('liked_tweets');

  Future<List<TweetItem>> _fetchTimeline(String endpoint) async {
    final userId = await _storage.read(key: _kUserId);
    if (userId == null) throw Exception('Twitter is not connected');
    final json = await _get('/users/$userId/$endpoint', query: {
      'max_results': '50',
      'tweet.fields': 'created_at,entities,author_id',
      'expansions': 'author_id',
      'user.fields': 'name,username',
    });

    final users = <String, Map<String, dynamic>>{};
    final includes = json['includes'] as Map<String, dynamic>?;
    for (final u in (includes?['users'] as List?) ?? const []) {
      users[u['id'] as String] = u as Map<String, dynamic>;
    }

    final items = <TweetItem>[];
    for (final t in (json['data'] as List?) ?? const []) {
      final tweet = t as Map<String, dynamic>;
      final author = users[tweet['author_id']];
      items.add(TweetItem(
        id: tweet['id'] as String,
        text: _expandUrls(tweet),
        authorName: author?['name'] as String?,
        authorUsername: author?['username'] as String?,
        createdAt: DateTime.tryParse(tweet['created_at'] as String? ?? ''),
        articleUrl: _firstExternalUrl(tweet),
      ));
    }
    return items;
  }

  /// Replaces t.co links in the tweet text with their expanded form.
  static String _expandUrls(Map<String, dynamic> tweet) {
    var text = tweet['text'] as String? ?? '';
    final urls = (tweet['entities']?['urls'] as List?) ?? const [];
    for (final u in urls) {
      final shortUrl = u['url'] as String?;
      final expanded = (u['expanded_url'] ?? u['unwound_url']) as String?;
      if (shortUrl != null && expanded != null) {
        text = text.replaceAll(shortUrl, expanded);
      }
    }
    return text;
  }

  static String? _firstExternalUrl(Map<String, dynamic> tweet) {
    final urls = (tweet['entities']?['urls'] as List?) ?? const [];
    for (final u in urls) {
      final expanded = (u['unwound_url'] ?? u['expanded_url']) as String?;
      if (expanded == null) continue;
      final host = Uri.tryParse(expanded)?.host ?? '';
      if (host.endsWith('twitter.com') || host.endsWith('x.com')) continue;
      return expanded;
    }
    return null;
  }

  // ----------------------------------------------------------------- tokens

  Future<Map<String, dynamic>> _get(String path,
      {Map<String, String>? query}) async {
    final token = await _validAccessToken();
    final uri =
        Uri.parse('$_apiBase$path').replace(queryParameters: query);
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode == 429) {
      throw Exception('Twitter rate limit reached, try again later');
    }
    if (response.statusCode != 200) {
      throw Exception('Twitter API error ${response.statusCode}: '
          '${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> _validAccessToken() async {
    final expiresAtRaw = await _storage.read(key: _kExpiresAt);
    final accessToken = await _storage.read(key: _kAccessToken);
    final expiresAt = int.tryParse(expiresAtRaw ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (accessToken != null && now < expiresAt - 60000) return accessToken;
    return _refresh();
  }

  Future<String> _refresh() async {
    final refreshToken = await _storage.read(key: _kRefreshToken);
    final clientId = await _storage.read(key: _kClientId);
    if (refreshToken == null || clientId == null) {
      throw Exception('Twitter is not connected');
    }
    final response = await http.post(Uri.parse(_tokenUrl), headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    }, body: {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    });
    if (response.statusCode != 200) {
      throw Exception('Twitter session expired, please reconnect '
          '(${response.statusCode})');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    await _storeTokens(json);
    return json['access_token'] as String;
  }

  Future<void> _storeTokens(Map<String, dynamic> json) async {
    await _storage.write(
        key: _kAccessToken, value: json['access_token'] as String);
    if (json['refresh_token'] != null) {
      await _storage.write(
          key: _kRefreshToken, value: json['refresh_token'] as String);
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 7200;
    final expiresAt =
        DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    await _storage.write(key: _kExpiresAt, value: expiresAt.toString());
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)])
        .join();
  }
}
