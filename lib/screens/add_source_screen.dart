import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../db/app_database.dart';
import '../models.dart';
import '../services/feed_parser.dart';

/// Adds an RSS/Atom source. Accepts either a feed URL directly or a website
/// URL — in that case the feed is discovered from the page's <link> tags.
class AddSourceScreen extends StatefulWidget {
  const AddSourceScreen({super.key});

  @override
  State<AddSourceScreen> createState() => _AddSourceScreenState();
}

class _AddSourceScreenState extends State<AddSourceScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      final (feedUrl, feedTitle) = await _resolveFeed(input);
      final source = await AppDatabase.instance.insertSource(Source(
        type: SourceType.rss,
        title: feedTitle,
        url: feedUrl,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      if (!mounted) return;
      Navigator.of(context).pop(source);
    } catch (e) {
      setState(() => _error = 'Could not add feed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Returns (feedUrl, feedTitle), discovering the feed if [url] is a page.
  Future<(String, String)> _resolveFeed(String url) async {
    final response = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (compatible; einkreader/0.1)',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final body = response.body;
    try {
      final feed = FeedParser.parse(body);
      return (url, feed.title);
    } on Exception {
      // Not a feed: look for a <link rel="alternate"> on the HTML page.
      final doc = html_parser.parse(body);
      final link = doc.querySelector(
              'link[rel="alternate"][type="application/rss+xml"]') ??
          doc.querySelector(
              'link[rel="alternate"][type="application/atom+xml"]');
      final href = link?.attributes['href'];
      if (href == null) {
        throw Exception('No RSS or Atom feed found at this address');
      }
      final feedUrl = Uri.parse(url).resolve(href).toString();
      final feedResponse = await http
          .get(Uri.parse(feedUrl))
          .timeout(const Duration(seconds: 20));
      final feed = FeedParser.parse(feedResponse.body);
      return (feedUrl, feed.title);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add source')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste a feed URL or a website address — the feed will be '
              'discovered automatically.',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Feed or website URL',
                hintText: 'https://example.com/feed.xml',
              ),
              onSubmitted: (_) => _add(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: const TextStyle(
                        fontSize: 14, fontStyle: FontStyle.italic)),
              ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _busy ? null : _add,
              child: Text(_busy ? 'Checking feed…' : 'Add feed'),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'To add Twitter bookmarks/likes or Nostr bookmarks/likes, '
              'connect your accounts in Settings.',
              style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}
