import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
import '../services/feed_parser.dart';
import '../services/nostr_service.dart';
import '../services/sync_service.dart';

/// Adds a source, whichever kind: an RSS/Atom feed (a feed URL directly or a
/// website/domain — the feed is discovered from the page's `<link>` tags), a
/// Twitter account (bookmarks feed via OAuth), or a Nostr npub (bookmarks and
/// likes feeds).
class AddSourceScreen extends StatefulWidget {
  const AddSourceScreen({super.key});

  @override
  State<AddSourceScreen> createState() => _AddSourceScreenState();
}

class _AddSourceScreenState extends State<AddSourceScreen> {
  final _db = AppDatabase.instance;
  final _twitter = SyncService.instance.twitter;
  final _controller = TextEditingController();
  final _clientIdController = TextEditingController();
  final _npubController = TextEditingController();
  bool _busy = false;
  bool _twitterBusy = false;
  bool _twitterConnected = false;
  String? _twitterUsername;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  @override
  void dispose() {
    _controller.dispose();
    _clientIdController.dispose();
    _npubController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    var connected = false;
    String? username;
    try {
      connected = await _twitter.isConnected;
      username = await _twitter.username;
    } catch (_) {
      // Secure storage unavailable (tests); treat as disconnected.
    }
    if (!mounted) return;
    setState(() {
      _twitterConnected = connected;
      _twitterUsername = username;
      _clientIdController.text = prefs.getString('twitter_client_id') ?? '';
      _npubController.text = prefs.getString('nostr_npub') ?? '';
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _connectTwitter() async {
    final clientId = _clientIdController.text.trim();
    if (clientId.isEmpty) {
      _toast('Enter your Twitter OAuth 2.0 Client ID first');
      return;
    }
    setState(() => _twitterBusy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('twitter_client_id', clientId);
      final username = await _twitter.connect(clientId);
      final source = await _db.insertSource(Source(
        type: SourceType.twitterBookmarks,
        title: 'Twitter Bookmarks',
        url: username,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      _toast('Connected as @$username');
      await _loadAccounts();
      // Pull in this source's items right away.
      unawaited(SyncService.instance.syncSources([source]));
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _twitterBusy = false);
    }
  }

  /// Drops the OAuth credentials only. The bookmarks source and its
  /// downloaded articles and highlights stay — reconnecting (e.g. to grant a
  /// new permission) must never cost data. Removing the source is an
  /// explicit act in Manage sources, with its own warning.
  Future<void> _disconnectTwitter() async {
    await _twitter.disconnect();
    _toast('Twitter disconnected — sources and articles kept');
    await _loadAccounts();
  }

  Future<void> _addNostr() async {
    final npub = _npubController.text.trim();
    if (npub.isEmpty) {
      _toast('Enter your npub first');
      return;
    }
    try {
      NostrService.decodeNpub(npub); // validate before saving
    } catch (e) {
      _toast('Invalid npub: $e');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nostr_npub', npub);
    final now = DateTime.now().millisecondsSinceEpoch;
    final bookmarks = await _db.insertSource(Source(
      type: SourceType.nostrBookmarks,
      title: 'Nostr Bookmarks',
      url: npub,
      createdAt: now,
    ));
    final likes = await _db.insertSource(Source(
      type: SourceType.nostrLikes,
      title: 'Nostr Likes',
      url: npub,
      createdAt: now,
    ));
    _toast('Nostr sources added');
    // Pull in the new sources' items right away.
    unawaited(SyncService.instance.syncSources([bookmarks, likes]));
  }

  Future<void> _add() async {
    var input = _controller.text.trim();
    if (input.isEmpty) return;
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      input = 'https://$input';
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppLogService.instance.info('Adding RSS source from input: $input');
      final (feedUrl, feedTitle) = await _resolveFeed(input);
      final source = await AppDatabase.instance.insertSource(
        Source(
          type: SourceType.rss,
          title: feedTitle,
          url: feedUrl,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await AppLogService.instance.info(
        'Finished adding RSS source: ${source.title} ${source.url}',
      );
      // Fetch this feed's articles right away; the feed updates as they land.
      unawaited(SyncService.instance.syncSources([source]));
      if (!mounted) return;
      Navigator.of(context).pop(source);
    } catch (e) {
      await AppLogService.instance.error(
        'Could not add RSS source from $input: $e',
      );
      setState(() => _error = 'Could not add feed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns (feedUrl, feedTitle), discovering the feed if [url] is a page.
  Future<(String, String)> _resolveFeed(String url) async {
    await AppLogService.instance.info('Loading RSS candidate URL: $url');
    final response = await http
        .get(
          Uri.parse(url),
          headers: {'User-Agent': 'Mozilla/5.0 (compatible; einkreader/0.1)'},
        )
        .timeout(const Duration(seconds: 20));
    await AppLogService.instance.info(
      'Loaded RSS candidate URL: $url HTTP ${response.statusCode}, '
      '${response.body.length} bytes',
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final body = response.body;
    try {
      final feed = FeedParser.parse(body);
      await AppLogService.instance.info(
        'Parsed direct RSS/Atom feed "$url": ${feed.items.length} items, '
        'title "${feed.title}"',
      );
      return (url, feed.title);
    } on Exception {
      // Not a feed: look for a <link rel="alternate"> on the HTML page.
      final doc = html_parser.parse(body);
      final link =
          doc.querySelector(
            'link[rel="alternate"][type="application/rss+xml"]',
          ) ??
          doc.querySelector(
            'link[rel="alternate"][type="application/atom+xml"]',
          );
      final href = link?.attributes['href'];
      if (href == null) {
        await AppLogService.instance.warn(
          'No RSS or Atom alternate link found at $url',
        );
        throw Exception('No RSS or Atom feed found at this address');
      }
      final feedUrl = Uri.parse(url).resolve(href).toString();
      await AppLogService.instance.info(
        'Discovered RSS/Atom feed for $url: $feedUrl',
      );
      final feedResponse = await http
          .get(Uri.parse(feedUrl))
          .timeout(const Duration(seconds: 20));
      await AppLogService.instance.info(
        'Loaded discovered RSS/Atom feed: $feedUrl '
        'HTTP ${feedResponse.statusCode}, ${feedResponse.body.length} bytes',
      );
      if (feedResponse.statusCode != 200) {
        throw Exception('Feed HTTP ${feedResponse.statusCode}');
      }
      final feed = FeedParser.parse(feedResponse.body);
      await AppLogService.instance.info(
        'Parsed discovered RSS/Atom feed "$feedUrl": '
        '${feed.items.length} items, title "${feed.title}"',
      );
      return (feedUrl, feed.title);
    }
  }

  @override
  Widget build(BuildContext context) {
    const sectionStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
    return Scaffold(
      appBar: AppBar(title: const Text('Add source')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('RSS feed', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Paste a feed URL, a website address or just a domain — the '
              'feed will be discovered automatically.',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Feed or website URL',
                hintText: 'example.com or https://example.com/feed.xml',
              ),
              onSubmitted: (_) => _add(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _busy ? null : _add,
              child: Text(_busy ? 'Checking feed…' : 'Add feed'),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Twitter / X', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Creates a feed from your Bookmarks. You need a '
              'free OAuth 2.0 Client ID from developer.x.com with callback '
              'URL einkreader://callback (see README).',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            if (_twitterConnected) ...[
              Text(
                'Connected as @${_twitterUsername ?? '?'}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _disconnectTwitter,
                child: const Text('Disconnect Twitter'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Disconnecting keeps your sources, articles and highlights.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ] else ...[
              TextField(
                controller: _clientIdController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'OAuth 2.0 Client ID',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _twitterBusy ? null : _connectTwitter,
                child: Text(_twitterBusy ? 'Connecting…' : 'Connect Twitter'),
              ),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Nostr', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Creates two feeds from your public bookmark list and likes. '
              'Only your public key (npub) is needed — never a private key.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _npubController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'npub',
                hintText: 'npub1…',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _addNostr,
              child: const Text('Add Nostr sources'),
            ),
          ],
        ),
      ),
    );
  }
}
