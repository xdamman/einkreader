import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/sync_service.dart';
import 'add_source_screen.dart';
import 'article_list_screen.dart';
import 'highlights_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase.instance;
  List<Source> _sources = [];
  Map<int, int> _unread = {};
  String _syncMessage = '';
  StreamSubscription<SyncProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _load();
    _progressSub = SyncService.instance.progress.stream.listen((p) {
      if (!mounted) return;
      setState(() => _syncMessage = p.running ? p.message : '');
      if (!p.running) _load();
    });
    // Refresh everything on launch so content is ready for offline reading.
    if (SyncService.instance.autoSyncOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(silent: true));
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
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

  Future<void> _sync({bool silent = false}) async {
    if (SyncService.instance.isSyncing) return;
    final summary = await SyncService.instance.syncAll();
    await _load();
    if (!silent && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(summary)));
    }
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
    final syncing = SyncService.instance.isSyncing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reader'),
        actions: [
          IconButton(
            tooltip: 'Update all sources',
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            onPressed: syncing ? null : _sync,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SettingsScreen()));
              _load();
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_syncMessage.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(width: 1))),
              child: Text(_syncMessage,
                  style: const TextStyle(
                      fontSize: 14, fontStyle: FontStyle.italic)),
            ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('All articles',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            onTap: () => _openList(null),
          ),
          ListTile(
            leading: const Icon(Icons.border_color_outlined),
            title: const Text('Highlights',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const HighlightsScreen()));
              _load();
            },
          ),
          const Divider(),
          Expanded(
            child: _sources.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No sources yet.\n\nAdd an RSS feed below, or connect '
                        'Twitter / Nostr in Settings.',
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
                        onTap: () => _openList(source),
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

  Future<void> _openList(Source? source) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArticleListScreen(source: source)));
    _load();
  }

  Future<void> _confirmDelete(Source source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(
            side: BorderSide(width: 1.5)),
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
