import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
import '../services/archive_store.dart';
import '../services/share_service.dart';
import '../services/sync_service.dart';
import '../widgets/article_feed.dart';
import '../widgets/clipboard_link_prompt.dart';
import '../widgets/highlight_list.dart';
import '../widgets/resume_reading.dart';
import 'add_source_screen.dart';
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

  /// Selected source on the Feed tab; null means "All" (or a folder, when
  /// [_feedFolderId] is set — the two are mutually exclusive).
  int? _feedSourceId;

  /// Selected folder on the Feed tab: filters to all its sources.
  int? _feedFolderId;
  List<Article> _articles = [];
  List<Highlight> _highlights = [];
  List<Source> _sources = [];
  List<Folder> _folders = [];
  Map<int, String> _sourceTitles = {};

  /// Sources currently being synced, shown with a spinner in the feed strip.
  /// Several refresh concurrently, so this is a set rather than a single id.
  final Set<int> _syncingSourceIds = {};
  bool _developerMode = false;
  StreamSubscription<SyncProgress>? _progressSub;
  StreamSubscription<void>? _logSub;
  StreamSubscription<String>? _shareSub;

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
    // Text shared into the app ("Share → einkreader") queues its link to
    // To Read; a shared browser selection also becomes a highlight.
    _shareSub = ShareLinkService.instance.texts.stream.listen(_onSharedText);
    ShareLinkService.instance.init();
    // Refresh everything on launch so content is ready for offline reading.
    if (SyncService.instance.autoSyncOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(silent: true));
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _logSub?.cancel();
    _shareSub?.cancel();
    super.dispose();
  }

  Future<void> _onSharedText(String text) async {
    final link = ShareLinkService.parse(text);
    if (link == null) {
      // The share sheet lists us for any text; without a URL there is
      // nothing to queue — say so instead of silently dropping it.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No link in the shared text — nothing to save')));
      return;
    }
    final saved = await _db.saveLinkForLater(url: link.url, title: link.title);
    // A shared selection becomes a highlight: painted inline once the
    // article's content is downloaded, and listed under Highlights.
    if (link.quote != null) {
      await _db.insertHighlightIfNew(Highlight(
        articleId: saved.id!,
        text: link.quote!,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      try {
        await ArchiveStore.instance.writeHighlights(await _db.getHighlights());
      } catch (_) {
        // Archive not available (e.g. storage not mounted); the highlight is
        // still in the database and exported on the next rewrite.
      }
    }
    await _startDownload(saved);
  }

  /// Post-save handling shared by the share sheet and the clipboard prompt:
  /// kick off the download right away when online (otherwise the next sync
  /// picks it up), refresh the feed, and confirm.
  Future<void> _startDownload(Article saved) async {
    final online = await SyncService.instance.isOnline();
    if (online && saved.fetched == 0) {
      unawaited(SyncService.instance.downloadArticle(saved.id!));
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(online
            ? 'Saved to To Read — downloading'
            : 'Saved to To Read — will download when back online')));
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
      final folders = await _db.getFolders();
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
        _sources = sources;
        _folders = folders;
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
        title: const Text('eInk Reader'),
        actions: [
          IconButton(
            tooltip: 'Update all sources',
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: syncing ? null : _sync,
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
      // Slim, dismissible offer to save a URL sitting in the clipboard.
      bottomNavigationBar: ClipboardLinkPrompt(onSaved: _startDownload),
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

  /// Opens the source-management screen and refreshes on return.
  Future<void> _openSources() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SourcesScreen()));
    _load();
  }

  /// Bottom sheet offering the two ways to add a first source: connecting
  /// Twitter/X (in Settings) or adding an RSS feed.
  Future<void> _showAddSourceSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Add a source',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('Connect Twitter / X'),
              subtitle: const Text('Your bookmarks as a feed'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SettingsScreen()));
                _load();
              },
            ),
            ListTile(
              leading: const Icon(Icons.rss_feed),
              title: const Text('Add RSS feed'),
              subtitle: const Text('Paste a feed or website URL'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AddSourceScreen()));
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Feed tab: a swipable filter strip above the article list — "All" first,
  /// then folders, then top-level sources, ordered by unread count then total
  /// items. Tapping a source filters the feed to it; tapping a folder opens a
  /// menu with the whole folder and its sources. With no sources configured
  /// yet, a centered call-to-action replaces the feed.
  Widget _buildFeed() {
    if (_sourceTitles.isEmpty) {
      return _EmptySourcesView(onAdd: _showAddSourceSheet);
    }
    final total = <int, int>{};
    final unread = <int, int>{};
    for (final article in _articles) {
      total[article.sourceId] = (total[article.sourceId] ?? 0) + 1;
      if (article.read == 0) {
        unread[article.sourceId] = (unread[article.sourceId] ?? 0) + 1;
      }
    }
    int compareFilters(_SourceFilter a, _SourceFilter b) {
      final byUnread = b.unread.compareTo(a.unread);
      return byUnread != 0 ? byUnread : b.total.compareTo(a.total);
    }

    _SourceFilter filterFor(int id) => _SourceFilter(
          id: id,
          title: _sourceTitles[id] ?? 'Unknown',
          unread: unread[id] ?? 0,
          total: total[id] ?? 0,
        );

    final folderOf = {for (final s in _sources) s.id!: s.folderId};
    final topSources = total.keys
        .where((id) => folderOf[id] == null)
        .map(filterFor)
        .toList()
      ..sort(compareFilters);

    // A folder appears once any of its sources has articles; its counts
    // aggregate over its members.
    final folders = <_FolderFilter>[];
    for (final folder in _folders) {
      final memberIds = total.keys
          .where((id) => folderOf[id] == folder.id)
          .toList();
      if (memberIds.isEmpty) continue;
      final members = memberIds.map(filterFor).toList()..sort(compareFilters);
      folders.add(_FolderFilter(
        id: folder.id!,
        title: folder.title,
        unread: members.fold(0, (sum, m) => sum + m.unread),
        total: members.fold(0, (sum, m) => sum + m.total),
        members: members,
      ));
    }
    folders.sort((a, b) {
      final byUnread = b.unread.compareTo(a.unread);
      return byUnread != 0 ? byUnread : b.total.compareTo(a.total);
    });

    // Fall back to "All" if the selection no longer has any articles.
    final selectedId =
        total.containsKey(_feedSourceId) ? _feedSourceId : null;
    final selectedFolderId =
        folders.any((f) => f.id == _feedFolderId) ? _feedFolderId : null;
    final articles = selectedFolderId != null
        ? _articles
            .where((a) => folderOf[a.sourceId] == selectedFolderId)
            .toList()
        : selectedId == null
            ? _articles
            : _articles.where((a) => a.sourceId == selectedId).toList();
    final allUnread = unread.values.fold(0, (sum, value) => sum + value);

    final currentReads = ResumeReadingSection.currentReads(_articles);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (currentReads.isNotEmpty)
          ResumeReadingSection(
            articles: currentReads,
            sourceTitles: _sourceTitles,
            onChanged: _load,
          ),
        _SourceFilterBar(
          folders: folders,
          sources: topSources,
          selectedId: selectedId,
          selectedFolderId: selectedFolderId,
          allUnread: allUnread,
          syncingSourceIds: _syncingSourceIds,
          onSelected: (id) => setState(() {
            _feedSourceId = id;
            _feedFolderId = null;
          }),
          onFolderTap: _showFolderMenu,
          onEdit: _openSources,
        ),
        Expanded(
          child: ArticleFeed(
            articles: articles,
            sourceTitles: _sourceTitles,
            emptyMessage:
                'No articles yet.\n\nPull to sync, or tap the edit '
                'button above to manage sources.',
            onChanged: _load,
          ),
        ),
      ],
    );
  }

  /// The folder chip's contextual menu: the whole folder, or one of its
  /// sources.
  Future<void> _showFolderMenu(_FolderFilter folder) async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text('All in ${folder.title}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: folder.unread > 0 ? Text('${folder.unread}') : null,
              onTap: () => Navigator.pop(sheetContext, 'folder'),
            ),
            const Divider(height: 1),
            for (final member in folder.members)
              ListTile(
                title: Text(member.title),
                trailing: member.unread > 0 ? Text('${member.unread}') : null,
                onTap: () => Navigator.pop(sheetContext, member.id),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      if (choice == 'folder') {
        _feedFolderId = folder.id;
        _feedSourceId = null;
      } else {
        _feedSourceId = choice as int;
        _feedFolderId = null;
      }
    });
  }
}

/// Centered call-to-action shown on the Feed tab when no sources exist yet.
class _EmptySourcesView extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptySourcesView({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No sources yet',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add a source to start filling your reader.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text(
                'Add your first source',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                side: const BorderSide(width: 1.5),
              ),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
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

/// A folder chip in the Feed filter strip: aggregate counts over its member
/// sources, which its contextual menu lists.
class _FolderFilter {
  final int id;
  final String title;
  final int unread;
  final int total;
  final List<_SourceFilter> members;

  const _FolderFilter({
    required this.id,
    required this.title,
    required this.unread,
    required this.total,
    required this.members,
  });
}

/// Horizontally swipable strip of filter chips shown above the feed: "All"
/// first, then folders, then top-level sources (both supplied ordered).
class _SourceFilterBar extends StatelessWidget {
  final List<_FolderFilter> folders;
  final List<_SourceFilter> sources;
  final int? selectedId;
  final int? selectedFolderId;
  final int allUnread;
  final Set<int> syncingSourceIds;
  final ValueChanged<int?> onSelected;
  final ValueChanged<_FolderFilter> onFolderTap;

  /// Opens source management. Pinned to the right of the strip so it stays
  /// visible no matter how many sources scroll past under it.
  final VoidCallback onEdit;

  const _SourceFilterBar({
    required this.folders,
    required this.sources,
    required this.selectedId,
    required this.selectedFolderId,
    required this.allUnread,
    required this.syncingSourceIds,
    required this.onSelected,
    required this.onFolderTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  _SourceChip(
                    label: 'All',
                    count: allUnread,
                    selected: selectedId == null && selectedFolderId == null,
                    syncing: false,
                    onTap: () => onSelected(null),
                  ),
                  for (final folder in folders) ...[
                    const SizedBox(width: 8),
                    _SourceChip(
                      label: folder.title,
                      icon: Icons.folder_outlined,
                      count: folder.unread,
                      // Selected for the folder itself or a source inside it,
                      // since that source has no chip of its own.
                      selected: selectedFolderId == folder.id ||
                          folder.members.any((m) => m.id == selectedId),
                      syncing: folder.members
                          .any((m) => syncingSourceIds.contains(m.id)),
                      onTap: () => onFolderTap(folder),
                    ),
                  ],
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
            // Pinned edit affordance for the source list, with a divider so it
            // reads as separate from the scrolling chips.
            const SizedBox(
              height: 52,
              child: VerticalDivider(width: 1, thickness: 1),
            ),
            IconButton(
              tooltip: 'Edit sources',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
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

  /// Optional leading icon (folders show a folder glyph).
  final IconData? icon;

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
    this.icon,
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
            if (icon != null) ...[
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
            ],
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
