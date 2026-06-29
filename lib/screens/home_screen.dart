import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
import '../services/sync_service.dart';
import '../widgets/article_feed.dart';
import '../widgets/highlight_list.dart';
import 'settings_screen.dart';
import 'sources_screen.dart';

enum _HomeTab {
  feed('Feed'),
  toRead('To Read'),
  highlights('Highlights'),
  favorites('Favorites'),
  debug('Debug');

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

  /// Selected source on the Feed tab; null means "All".
  int? _feedSourceId;
  List<Article> _articles = [];
  List<Highlight> _highlights = [];
  Map<int, String> _sourceTitles = {};

  /// Sources currently being synced, shown with a spinner in the feed strip.
  /// Several refresh concurrently, so this is a set rather than a single id.
  final Set<int> _syncingSourceIds = {};
  bool _developerMode = false;
  StreamSubscription<SyncProgress>? _progressSub;
  StreamSubscription<void>? _logSub;

  @override
  void initState() {
    super.initState();
    _load();
    _progressSub = SyncService.instance.progress.stream.listen((p) {
      if (!mounted) return;
      setState(() {
        if (!p.running) {
          _syncingSourceIds.clear();
        } else if (p.sourceId != null) {
          if (p.done) {
            _syncingSourceIds.remove(p.sourceId);
          } else {
            _syncingSourceIds.add(p.sourceId!);
          }
        }
      });
      // Refresh the feed mid-sync as sources and downloads land, and once more
      // when the sync finishes.
      if (p.reload || !p.running) _load();
    });
    _logSub = AppLogService.instance.changes.stream.listen((_) {
      if (mounted) _loadDeveloperMode();
    });
    // Refresh everything on launch so content is ready for offline reading.
    if (SyncService.instance.autoSyncOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(silent: true));
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _logSub?.cancel();
    super.dispose();
  }

  bool _loading = false;
  bool _loadAgain = false;

  /// Reloads all home data. Frequent mid-sync reloads are coalesced: a request
  /// arriving while a load is in flight schedules exactly one more load after
  /// it, so the final state is always up to date without overlapping queries.
  Future<void> _load() async {
    if (_loading) {
      _loadAgain = true;
      return;
    }
    _loading = true;
    try {
      final articles = await _db.getArticles();
      final highlights = await _db.getHighlights();
      final sources = await _db.getSources();
      final developerMode =
          await AppLogService.instance.isDeveloperModeEnabled();
      await AppLogService.instance.debug(
        'Loaded home data: ${articles.length} articles, '
        '${highlights.length} highlights, ${sources.length} sources',
      );
      if (!mounted) return;
      setState(() {
        _articles = articles;
        _highlights = highlights;
        _sourceTitles = {for (final s in sources) s.id!: s.title};
        _developerMode = developerMode;
        if (!_developerMode && _tab == _HomeTab.debug) {
          _tab = _HomeTab.feed;
        }
      });
    } finally {
      _loading = false;
      if (_loadAgain) {
        _loadAgain = false;
        _load();
      }
    }
  }

  Future<void> _loadDeveloperMode() async {
    final developerMode = await AppLogService.instance.isDeveloperModeEnabled();
    if (!mounted) return;
    setState(() {
      _developerMode = developerMode;
      if (!_developerMode && _tab == _HomeTab.debug) {
        _tab = _HomeTab.feed;
      }
    });
  }

  Future<void> _sync({bool silent = false}) async {
    if (SyncService.instance.isSyncing) return;
    final summary = await SyncService.instance.syncAll();
    await _load();
    if (!silent && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(summary)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncing = SyncService.instance.isSyncing;
    final tabs =
        _developerMode
            ? _HomeTab.values
            : _HomeTab.values.where((tab) => tab != _HomeTab.debug);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reader'),
        actions: [
          IconButton(
            tooltip: 'Update all sources',
            icon:
                syncing
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.sync),
            onPressed: syncing ? null : _sync,
          ),
          IconButton(
            tooltip: 'Sources',
            icon: const Icon(Icons.rss_feed),
            onPressed: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SourcesScreen()));
              _load();
            },
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
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
            tabs: tabs.toList(),
            onSelected: (tab) => setState(() => _tab = tab),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case _HomeTab.feed:
        return _buildFeed();
      case _HomeTab.toRead:
        return ArticleFeed(
          articles: _articles.where((a) => a.readLater == 1).toList(),
          sourceTitles: _sourceTitles,
          emptyMessage:
              'Nothing saved to read later.\n\nTap the bookmark '
              'icon on any article in the feed.',
          onChanged: _load,
        );
      case _HomeTab.highlights:
        return HighlightList(highlights: _highlights, onChanged: _load);
      case _HomeTab.favorites:
        return ArticleFeed(
          articles: _articles.where((a) => a.favorite == 1).toList(),
          sourceTitles: _sourceTitles,
          emptyMessage:
              'No favorites yet.\n\nUse the favorite button at '
              'the end of an article.',
          rowAction: FeedRowAction.unfavorite,
          onChanged: _load,
        );
      case _HomeTab.debug:
        return const _DebugLogView();
    }
  }

  /// Feed tab: a swipable source filter strip above the article list. Sources
  /// are ordered by unread count, then total items; tapping one filters the
  /// feed to that source, with "All" showing everything.
  Widget _buildFeed() {
    final total = <int, int>{};
    final unread = <int, int>{};
    for (final article in _articles) {
      total[article.sourceId] = (total[article.sourceId] ?? 0) + 1;
      if (article.read == 0) {
        unread[article.sourceId] = (unread[article.sourceId] ?? 0) + 1;
      }
    }
    final sources = total.keys
        .map((id) => _SourceFilter(
              id: id,
              title: _sourceTitles[id] ?? 'Unknown',
              unread: unread[id] ?? 0,
              total: total[id] ?? 0,
            ))
        .toList()
      ..sort((a, b) {
        final byUnread = b.unread.compareTo(a.unread);
        return byUnread != 0 ? byUnread : b.total.compareTo(a.total);
      });

    // Fall back to "All" if the selected source no longer has any articles.
    final selectedId =
        sources.any((s) => s.id == _feedSourceId) ? _feedSourceId : null;
    final articles = selectedId == null
        ? _articles
        : _articles.where((a) => a.sourceId == selectedId).toList();
    final allUnread = unread.values.fold(0, (sum, value) => sum + value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sources.isNotEmpty)
          _SourceFilterBar(
            sources: sources,
            selectedId: selectedId,
            allUnread: allUnread,
            syncingSourceIds: _syncingSourceIds,
            onSelected: (id) => setState(() => _feedSourceId = id),
          ),
        Expanded(
          child: ArticleFeed(
            articles: articles,
            sourceTitles: _sourceTitles,
            emptyMessage:
                'No articles yet.\n\nAdd sources with the feed '
                'button above, then sync.',
            onChanged: _load,
          ),
        ),
      ],
    );
  }
}

/// One selectable source in the Feed filter strip, with its unread and total
/// item counts.
class _SourceFilter {
  final int id;
  final String title;
  final int unread;
  final int total;

  const _SourceFilter({
    required this.id,
    required this.title,
    required this.unread,
    required this.total,
  });
}

/// Horizontally swipable strip of source chips shown above the feed. "All" is
/// always first; the rest are supplied already ordered.
class _SourceFilterBar extends StatelessWidget {
  final List<_SourceFilter> sources;
  final int? selectedId;
  final int allUnread;
  final Set<int> syncingSourceIds;
  final ValueChanged<int?> onSelected;

  const _SourceFilterBar({
    required this.sources,
    required this.selectedId,
    required this.allUnread,
    required this.syncingSourceIds,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            _SourceChip(
              label: 'All',
              count: allUnread,
              selected: selectedId == null,
              syncing: false,
              onTap: () => onSelected(null),
            ),
            for (final source in sources) ...[
              const SizedBox(width: 8),
              _SourceChip(
                label: source.title,
                count: source.unread,
                selected: selectedId == source.id,
                syncing: syncingSourceIds.contains(source.id),
                onTap: () => onSelected(source.id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Flat, e-ink friendly pill: solid black when selected, outlined otherwise,
/// with a trailing unread count when there is one.
class _SourceChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;

  /// While true, a spinner replaces the unread count to show this source is
  /// being updated.
  final bool syncing;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.syncing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : Colors.black;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? Colors.black : Colors.white,
          border: Border.all(width: 1.5),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
            if (syncing) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              ),
            ] else if (count > 0) ...[
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Flat, e-ink friendly tab strip: the active tab is solid black.
class _TabBar extends StatelessWidget {
  final _HomeTab active;
  final List<_HomeTab> tabs;
  final ValueChanged<_HomeTab> onSelected;

  const _TabBar({
    required this.active,
    required this.tabs,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1.5)),
      ),
      child: Row(
        children: [
          for (final tab in tabs)
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

class _DebugLogView extends StatefulWidget {
  const _DebugLogView();

  @override
  State<_DebugLogView> createState() => _DebugLogViewState();
}

class _DebugLogViewState extends State<_DebugLogView> {
  List<AppLogEntry> _entries = [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = AppLogService.instance.changes.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await AppLogService.instance.entries();
    if (!mounted) return;
    setState(() => _entries = entries.reversed.toList());
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) {
      return const Center(
        child: Text('No logs yet.', style: TextStyle(fontSize: 16)),
      );
    }
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_entries.length} recent log entries',
                  style: const TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: () async {
                  await AppLogService.instance.clear();
                  await _load();
                },
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  '${_time(entry.time)} ${entry.level.toUpperCase()}\n'
                  '${entry.message}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _time(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}
