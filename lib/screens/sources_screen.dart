import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'add_source_screen.dart';
import 'article_list_screen.dart';

/// Manage sources: list with unread counts, add RSS feeds, remove with a
/// long-press. Twitter/Nostr sources are added from Settings.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _db = AppDatabase.instance;
  List<Source> _sources = [];
  Map<int, int> _unread = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = await _db.getSources();
    final unread = await _db.unreadCountsBySource();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _unread = unread;
    });
  }

  IconData _iconFor(SourceType type) => switch (type) {
        SourceType.rss => Icons.rss_feed,
        SourceType.twitterBookmarks => Icons.bookmark_outline,
        SourceType.twitterLikes => Icons.favorite_outline,
        SourceType.nostrBookmarks => Icons.bookmark_outline,
        SourceType.nostrLikes => Icons.favorite_outline,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _sources.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No sources yet.\n\nAdd an RSS feed below, or '
                        'connect Twitter / Nostr in Settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _sources.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (context, index) {
                      final source = _sources[index];
                      final unread = _unread[source.id] ?? 0;
                      return ListTile(
                        leading: Icon(_iconFor(source.type)),
                        title: Text(source.title,
                            style: const TextStyle(fontSize: 17)),
                        subtitle: Text(source.type.label,
                            style: const TextStyle(fontSize: 13)),
                        trailing: unread > 0
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration:
                                    BoxDecoration(border: Border.all()),
                                child: Text('$unread',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              )
                            : null,
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  ArticleListScreen(source: source)));
                          _load();
                        },
                        onLongPress: () => _confirmDelete(source),
                      );
                    },
                  ),
          ),
          const Divider(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add source'),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AddSourceScreen()));
                  _load();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Source source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: Text('Remove "${source.title}"?'),
        content: const Text(
            'Its downloaded articles and highlights will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await _db.deleteSource(source.id!);
      _load();
    }
  }
}
