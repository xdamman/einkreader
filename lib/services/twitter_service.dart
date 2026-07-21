import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'twitter_markdown.dart';

/// A tweet reduced to what the reader needs.
class TweetItem {
  final String id;
  final String text;
  final String? authorName;
  final String? authorUsername;
  final DateTime? createdAt;

  /// First non-twitter URL in the tweet, used to fetch the full article.
  final String? articleUrl;

  /// True when this is a native long-form post (note tweet / X Article):
  /// [text] already holds the full body, so it is the article itself.
  final bool isLongForm;

  /// Status id of another X post this tweet links to, when present. Used to
  /// inline a referenced native article below the tweet.
  final String? linkedTweetId;

  /// The author's user id, needed to look up self-replies (threads).
  final String? authorId;

  const TweetItem({
    required this.id,
    required this.text,
    this.authorName,
    this.authorUsername,
    this.createdAt,
    this.articleUrl,
    this.isLongForm = false,
    this.linkedTweetId,
    this.authorId,
  });

  String get tweetUrl => 'https://x.com/${authorUsername ?? 'i'}/status/$id';

  /// Returns a copy whose [text] is this tweet followed by a horizontal rule
  /// and the full body of a native article it links to.
  TweetItem withArticle(String articleText) => TweetItem(
        id: id,
        text: '$text\n\n---\n\n$articleText',
        authorName: authorName,
        authorUsername: authorUsername,
        createdAt: createdAt,
        articleUrl: articleUrl,
        isLongForm: isLongForm,
        linkedTweetId: linkedTweetId,
        authorId: authorId,
      );

  /// Returns a copy carrying a whole self-thread as [text]. Marked long-form:
  /// the thread IS the article — keep it rather than downloading any page the
  /// first tweet links to.
  TweetItem asThread(String threadText) => TweetItem(
        id: id,
        text: threadText,
        authorName: authorName,
        authorUsername: authorUsername,
        createdAt: createdAt,
        articleUrl: articleUrl,
        isLongForm: true,
        linkedTweetId: linkedTweetId,
        authorId: authorId,
      );
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
  // tweet.write enables "Share on Twitter" from the reader; connections made
  // before it was added must be reconnected in Settings to grant it.
  static const _scopes =
      'tweet.read tweet.write users.read bookmark.read offline.access';

  static const _storage = FlutterSecureStorage();
  static const _kAccessToken = 'twitter_access_token';
  static const _kRefreshToken = 'twitter_refresh_token';
  static const _kExpiresAt = 'twitter_expires_at';
  static const _kClientId = 'twitter_client_id';
  static const _kUserId = 'twitter_user_id';
  static const _kUsername = 'twitter_username';

  final http.Client _client;

  /// Test seam: when set, used instead of the stored OAuth token so the API
  /// layer can be driven by a fake [http.Client] without a real connection.
  final Future<String> Function()? _accessTokenOverride;

  TwitterService({http.Client? client, Future<String> Function()? accessToken})
      : _client = client ?? http.Client(),
        _accessTokenOverride = accessToken;

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

    final tokenResponse = await _client.post(Uri.parse(_tokenUrl), headers: {
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

  /// Standard fields needed to render a tweet, including the long-form body.
  static const _tweetQuery = {
    // note_tweet carries the full body of "longer tweets"; article carries the
    // full body (plain_text) of native X Articles.
    'tweet.fields':
        'created_at,entities,author_id,note_tweet,referenced_tweets,article',
    'expansions': 'author_id,referenced_tweets.id,attachments.media_keys',
    'user.fields': 'name,username',
    'media.fields': 'url,preview_image_url,type',
  };

  Future<List<TweetItem>> _fetchTimeline(String endpoint) async {
    final userId = await _storage.read(key: _kUserId);
    if (userId == null) throw Exception('Twitter is not connected');
    final json = await _get('/users/$userId/$endpoint', query: {
      'max_results': '50',
      ..._tweetQuery,
    });

    final users = _usersFrom(json);
    final media = _mediaFrom(json);
    final items = <TweetItem>[];
    for (final t in (json['data'] as List?) ?? const []) {
      items.add(_parseTweet(t as Map<String, dynamic>, users, media));
    }
    // Inline any referenced native article below the tweet that links to it.
    return Future.wait(items.map(_withLinkedArticle));
  }

  /// Fetches a single tweet by id. A self-thread is returned whole (tweets
  /// separated by horizontal rules); otherwise, when the tweet links to
  /// another X post that is a native long-form article, the item's [text]
  /// holds the tweet followed by a rule and the full article body.
  Future<TweetItem> fetchTweet(String id) async {
    final item = await _fetchTweet(id);
    return await threadOf(item) ?? await _withLinkedArticle(item);
  }

  Future<TweetItem> _fetchTweet(String id) async {
    final json = await _get('/tweets/$id', query: _tweetQuery);
    return _parseTweet(
        json['data'] as Map<String, dynamic>, _usersFrom(json), _mediaFrom(json));
  }

  /// If [item] links to another X post that is a native article, fetches it and
  /// appends its full body below a horizontal rule. Network errors are ignored
  /// so a missing reference never breaks a sync.
  Future<TweetItem> _withLinkedArticle(TweetItem item) async {
    final linkedId = item.linkedTweetId;
    if (linkedId == null || linkedId == item.id) return item;
    try {
      final article = await _fetchTweet(linkedId);
      if (!article.isLongForm) return item;
      return item.withArticle(article.text);
    } catch (_) {
      return item;
    }
  }

  static Map<String, Map<String, dynamic>> _usersFrom(
      Map<String, dynamic> json) {
    final users = <String, Map<String, dynamic>>{};
    final includes = json['includes'] as Map<String, dynamic>?;
    for (final u in (includes?['users'] as List?) ?? const []) {
      users[u['id'] as String] = u as Map<String, dynamic>;
    }
    return users;
  }

  /// media_key -> image URL, from the response includes, so article cover and
  /// attached images can be rendered.
  static Map<String, String> _mediaFrom(Map<String, dynamic> json) {
    final media = <String, String>{};
    final includes = json['includes'] as Map<String, dynamic>?;
    for (final m in (includes?['media'] as List?) ?? const []) {
      final key = m['media_key'] as String?;
      final url = (m['url'] ?? m['preview_image_url']) as String?;
      if (key != null && url != null) media[key] = url;
    }
    return media;
  }

  static TweetItem _parseTweet(Map<String, dynamic> tweet,
      Map<String, Map<String, dynamic>> users, Map<String, String> media) {
    final author = users[tweet['author_id']];
    // Link/article references come from the note body when present, else the
    // tweet itself; an article's own entities point only at its own URL.
    final body = noteOf(tweet) ?? tweet;
    return TweetItem(
      id: tweet['id'] as String,
      text: tweetBodyMarkdown(tweet, mediaUrls: media),
      authorName: author?['name'] as String?,
      authorUsername: author?['username'] as String?,
      createdAt: DateTime.tryParse(tweet['created_at'] as String? ?? ''),
      articleUrl: firstExternalUrl(body),
      isLongForm: isLongFormTweet(tweet),
      linkedTweetId: linkedTweetId(tweet, body),
      authorId: tweet['author_id'] as String?,
    );
  }

  /// Detects a self-thread under [item]: consecutive replies by the same
  /// author. Returns the item carrying the whole thread — tweets separated by
  /// horizontal rules, each with its own images — or null when [item] has no
  /// thread. One author-timeline lookup (since the root tweet) finds the
  /// chain; errors just mean "no thread" so a sync never breaks on it.
  Future<TweetItem?> threadOf(TweetItem item) async {
    final authorId = item.authorId;
    if (authorId == null) return null;
    try {
      final json = await _get('/users/$authorId/tweets', query: {
        'since_id': item.id,
        'max_results': '100',
        ..._tweetQuery,
      });
      final data = (json['data'] as List?) ?? const [];
      if (data.isEmpty) return null;
      final media = _mediaFrom(json);

      String? repliedTo(Map<String, dynamic> tweet) {
        for (final ref
            in (tweet['referenced_tweets'] as List?) ?? const []) {
          if (ref is Map && ref['type'] == 'replied_to') {
            return ref['id'] as String?;
          }
        }
        return null;
      }

      // The author's replies indexed by the tweet they answer.
      final byRepliedTo = <String, Map<String, dynamic>>{};
      for (final tweet in data.cast<Map<String, dynamic>>()) {
        final target = repliedTo(tweet);
        if (target != null) byRepliedTo.putIfAbsent(target, () => tweet);
      }

      // Walk the chain from the root.
      final parts = <String>[item.text];
      var currentId = item.id;
      while (parts.length < 100) {
        final next = byRepliedTo[currentId];
        if (next == null) break;
        parts.add(tweetBodyMarkdown(next, mediaUrls: media));
        currentId = next['id'] as String;
      }
      if (parts.length == 1) return null;
      await _log((log) =>
          log.info('Twitter: thread of ${parts.length} tweets under ${item.id}'));
      return item.asThread(parts.join('\n\n---\n\n'));
    } catch (e) {
      await _log((log) =>
          log.warn('Twitter: thread lookup failed for ${item.id}: $e'));
      return null;
    }
  }

  /// Best-effort logging: threadOf must never throw, including from the log
  /// call itself (unavailable in plain unit tests).
  Future<void> _log(Future<void> Function(AppLogService) write) async {
    try {
      await write(AppLogService.instance);
    } catch (_) {}
  }

  int? _cachedTweetMaxLength;

  /// Character budget for a tweet on this account. The API exposes no
  /// explicit length field; the available signal is users/me verified_type:
  /// Premium ("blue") and business accounts can post long tweets (25k
  /// chars), everyone else 280. Cached per session; falls back to 280 when
  /// the lookup fails.
  Future<int> tweetMaxLength() async {
    final cached = _cachedTweetMaxLength;
    if (cached != null) return cached;
    try {
      final json = await _get('/users/me',
          query: {'user.fields': 'verified_type'});
      final type =
          ((json['data'] as Map<String, dynamic>?)?['verified_type']
                  as String?) ??
              'none';
      return _cachedTweetMaxLength =
          (type == 'blue' || type == 'business') ? 25000 : 280;
    } catch (_) {
      return 280; // Unknown plan: use the universal limit; don't cache.
    }
  }

  /// The id of the tweet a twitter.com / x.com status URL points to, or null
  /// for any other URL. Lets shares of tweet-articles become native quote
  /// tweets instead of pasted links.
  static String? tweetIdFromUrl(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    const tweetHosts = ['twitter.com', 'x.com'];
    if (!tweetHosts.any((h) => host == h || host.endsWith('.$h'))) {
      return null;
    }
    final segments = uri.pathSegments;
    final statusIndex =
        segments.indexWhere((s) => s == 'status' || s == 'statuses');
    if (statusIndex == -1 || statusIndex + 1 >= segments.length) return null;
    final id = segments[statusIndex + 1];
    return RegExp(r'^\d+$').hasMatch(id) ? id : null;
  }

  /// Posts a tweet, optionally as a native quote of [quoteTweetId]. Needs the
  /// tweet.write scope: accounts connected before that scope was requested
  /// get a 403 until reconnected. Every step logs with a "Twitter:" prefix so
  /// the debug screen's search surfaces the whole story of a post.
  Future<void> postTweet(String text, {String? quoteTweetId}) async {
    await AppLogService.instance.info(
      'Twitter: posting tweet (${text.length} chars'
      '${quoteTweetId != null ? ', quoting $quoteTweetId' : ''})',
    );
    final String token;
    try {
      token = await _validAccessToken();
    } catch (e) {
      await AppLogService.instance
          .error('Twitter: no valid access token for posting: $e');
      rethrow;
    }
    final response = await _client.post(
      Uri.parse('$_apiBase/tweets'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'text': text,
        if (quoteTweetId != null) 'quote_tweet_id': quoteTweetId,
      }),
    );
    if (response.statusCode == 403) {
      await AppLogService.instance
          .error('Twitter: post refused (403): ${response.body}');
      throw Exception(
          'Twitter refused the post. Reconnect Twitter (Add source) to '
          'grant the posting permission.');
    }
    if (response.statusCode != 201) {
      await AppLogService.instance.error(
          'Twitter: post failed (HTTP ${response.statusCode}): '
          '${response.body}');
      throw Exception('Twitter API error ${response.statusCode}: '
          '${response.body}');
    }
    final id =
        ((jsonDecode(response.body) as Map<String, dynamic>?)?['data']
            as Map<String, dynamic>?)?['id'];
    await AppLogService.instance.info('Twitter: tweet posted, id $id');
  }

  // ----------------------------------------------------------------- tokens

  Future<Map<String, dynamic>> _get(String path,
      {Map<String, String>? query}) async {
    final token = await _validAccessToken();
    final uri =
        Uri.parse('$_apiBase$path').replace(queryParameters: query);
    final response = await _client
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
    final override = _accessTokenOverride;
    if (override != null) return override();
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
    final response = await _client.post(Uri.parse(_tokenUrl), headers: {
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
