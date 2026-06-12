import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/sync_service.dart';
import '../widgets/article_feed.dart';
import '../widgets/highlight_list.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';

enum _HomeTab {
  feed('Feed'),
  toRead('To Read'),
  highlights('Highlights'),
  favorites('Favorites');

  final String label;
  const _HomeTab(this.label);
}

/// Main screen: a date-grouped feed of the latest articles across all
/// sources, with tabs for To Read, Highlights and Favorites.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase.instance;
  _HomeTab _tab = _HomeTab.feed;
  List<Article> _articles = [];
  List<Highlight> _highlights = [];
  Map<int, String> _sourceTitles = {};
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
    final articles = await _db.getArticles();
    final highlights = await _db.getHighlights();
    final sources = await _db.getSources();
    if (!mounted) return;
    setState(() {
      _articles = articles;
      _highlights = highlights;
      _sourceTitles = {for (final s in sources) s.id!: s.title};
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
            tooltip: 'Sources',
            icon: const Icon(Icons.rss_feed),
            onPressed: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SourcesScreen()));
              _load();
            },
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()));
              _load();
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabBar(
            active: _tab,
            onSelected: (tab) => setState(() => _tab = tab),
          ),
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
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case _HomeTab.feed:
        return ArticleFeed(
          articles: _articles,
          sourceTitles: _sourceTitles,
          emptyMessage: 'No articles yet.\n\nAdd sources with the feed '
              'button above, then sync.',
          onChanged: _load,
        );
      case _HomeTab.toRead:
        return ArticleFeed(
          articles: _articles.where((a) => a.readLater == 1).toList(),
          sourceTitles: _sourceTitles,
          emptyMessage: 'Nothing saved to read later.\n\nTap the bookmark '
              'icon on any article in the feed.',
          onChanged: _load,
        );
      case _HomeTab.highlights:
        return HighlightList(highlights: _highlights, onChanged: _load);
      case _HomeTab.favorites:
        return ArticleFeed(
          articles: _articles.where((a) => a.favorite == 1).toList(),
          sourceTitles: _sourceTitles,
          emptyMessage: 'No favorites yet.\n\nUse the favorite button at '
              'the end of an article.',
          rowAction: FeedRowAction.unfavorite,
          onChanged: _load,
        );
    }
  }
}

/// Flat, e-ink friendly tab strip: the active tab is solid black.
class _TabBar extends StatelessWidget {
  final _HomeTab active;
  final ValueChanged<_HomeTab> onSelected;

  const _TabBar({required this.active, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1.5)),
      ),
      child: Row(
        children: [
          for (final tab in _HomeTab.values)
            Expanded(
              child: InkWell(
                onTap: () => onSelected(tab),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  color: tab == active ? Colors.black : Colors.white,
                  child: Text(
                    tab.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: tab == active ? Colors.white : Colors.black,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
