import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
import '../services/archive_store.dart';
import '../services/feedback_service.dart';
import '../services/outbox_service.dart';
import '../services/plugin_service.dart';
import '../services/profile_service.dart';
import '../services/share_service.dart';
import '../services/sync_service.dart';
import '../widgets/article_feed.dart';
import '../widgets/clipboard_link_prompt.dart';
import '../widgets/highlight_list.dart';
import '../widgets/inbox_header.dart';
import '../widgets/notice.dart';
import '../widgets/resume_reading.dart';
import '../widgets/profile_switcher.dart';
import '../widgets/reconnect_twitter.dart';
import '../widgets/shared_list.dart';
import 'add_source_screen.dart';
import 'feedback_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'suggested_sources_screen.dart';

enum _HomeTab {
  feed('Feed'),
  toRead('To Read'),
  read('Read'),
  highlights('Highlights'),
  shared('Shared'),
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

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  final _db = AppDatabase.instance;
  _HomeTab _tab = _HomeTab.feed;

  /// Selected source on the Feed tab; null means "All" (or a folder, when
  /// [_feedFolderId] is set — the two are mutually exclusive).
  int? _feedSourceId;

  /// Selected folder on the Feed tab: filters to all its sources.
  int? _feedFolderId;

  /// Within a Twitter source (which behaves like a folder of accounts):
  /// the selected author, or null for all.
  String? _feedAuthor;

  /// Sentinel for the collapsed "Others" author chip.
  static const _othersAuthor = '__others__';

  /// Sentinel for the Inbox's "Other senders" chip: emails from senders
  /// not accepted yet, waiting for Accept / Delete.
  static const _requestsAuthor = '__requests__';
  List<Article> _articles = [];
  List<Highlight> _highlights = [];
  List<Share> _shares = [];

  /// ★ filter on the Read tab (Favorites folded in as a chip).
  bool _readFavoritesOnly = false;

  /// Source filters on the Read and Highlights tabs (null = all sources).
  int? _readSourceId;
  int? _highlightsSourceId;
  List<Source> _sources = [];
  List<Folder> _folders = [];

  /// The built-in Inbox (content emailed to name@einkreader.app): always
  /// in the chip strip, even empty, so its address is easy to find. Null
  /// when the Email plugin is off.
  int? _inboxSourceId;

  /// Whether a sync has anything to do: a source to refresh, or an Inbox
  /// address to fetch email for. Without either the sync icon is hidden.
  bool _hasSomethingToSync = false;
  Map<int, String> _sourceTitles = {};

  /// Sources currently being synced, shown with a spinner in the feed strip.
  /// Several refresh concurrently, so this is a set rather than a single id.
  final Set<int> _syncingSourceIds = {};

  /// New articles whose row came on screen in the feed during this visit.
  /// They stay bold until the reader leaves the app, then are recorded as
  /// seen: the next visit only flags what arrived since.
  final Set<int> _shownIds = {};
  bool _developerMode = false;
  StreamSubscription<SyncProgress>? _progressSub;
  StreamSubscription<void>? _logSub;
  StreamSubscription<String>? _shareSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      // Replies and reactions to the reader's feedback ride along each sync.
      if (!p.running) FeedbackService().refreshNotifications();
    });
    // The badge shows what's stored at once; the relays are asked on launch
    // (same switch as the launch sync, which tests turn off).
    FeedbackService().unseenByThread();
    if (SyncService.instance.autoSyncOnLaunch) {
      FeedbackService().refreshNotifications();
    }
    _logSub = AppLogService.instance.changes.stream.listen((_) {
      if (mounted) _loadDeveloperMode();
    });
    // Text shared into the app ("Share → einkreader") queues its link to
    // To Read; a shared browser selection also becomes a highlight.
    _shareSub = ShareLinkService.instance.texts.stream.listen(_onSharedText);
    ShareLinkService.instance.init();
    OutboxService.instance.refreshCount();
    // Refresh everything on launch so content is ready for offline reading.
    if (SyncService.instance.autoSyncOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(silent: true));
    } else {
      // No auto-sync: still pick up highlights edited into highlights.md by
      // other apps (a no-op when the file hasn't changed).
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final imported =
            await SyncService.instance.importHighlightsFromArchive();
        if (imported > 0 && mounted) _load();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressSub?.cancel();
    _logSub?.cancel();
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app (or the screen going to sleep) ends the visit.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _recordShown();
    }
  }

  /// Records the articles shown on screen this visit as seen.
  Future<void> _recordShown() async {
    if (_shownIds.isEmpty) return;
    final ids = _shownIds.toList();
    _shownIds.clear();
    await _db.markArticlesSeen(ids);
    await _load();
  }

  Future<void> _onSharedText(String text) async {
    final link = ShareLinkService.parse(text);
    if (link == null) {
      // The share sheet lists us for any text; without a URL there is
      // nothing to queue — say so instead of silently dropping it.
      if (!mounted) return;
      showNotice(context, 'No link in the shared text — nothing to save');
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
    showNotice(
        context,
        online
            ? 'Saved to To Read — downloading'
            : 'Saved to To Read — will download when back online');
  }

  bool _loading = false;
  bool _loadAgain = false;

  /// Reloads all home data. Frequent mid-sync reloads are coalesced: a request
  /// arriving while a load is in flight schedules exactly one more load after
  /// it, so the final state is always up to date without overlapping queries.
  /// False until the first load completes — the data is all local, so
  /// this flips within a frame or two; until then the feed renders blank
  /// rather than flashing the "add a source" call-to-action.
  bool _everLoaded = false;

  Future<void> _load() async {
    if (_loading) {
      _loadAgain = true;
      return;
    }
    _loading = true;
    try {
      final inbox = await PluginService.instance.emailActive
          ? await _db.ensureEmailSource()
          : null;
      final hasInboxAddress = inbox != null &&
          await ProfileService.instance.enabled &&
          await ProfileService.instance.nip05Address != null;
      final articles =
          await _db.getArticles(withContent: false, limit: null);
      final highlights = await _db.getHighlights();
      final shares = await _db.getShares();
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
        _shares = shares;
        _sources = sources;
        _folders = folders;
        _inboxSourceId = inbox?.id;
        _hasSomethingToSync = hasInboxAddress ||
            sources.any((s) =>
                s.type != SourceType.email &&
                s.type != SourceType.savedLinks);
        _sourceTitles = {for (final s in sources) s.id!: s.title};
        _developerMode = developerMode;
        _everLoaded = true;
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
      showNotice(context, summary);
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
          // Universal search across sources, authors, titles, content and
          // highlights — first in the row so it is always at hand.
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchScreen()));
              _load();
            },
          ),
          // Visible only while something couldn't be sent (e.g. a tweet
          // posted offline): a clear signal that work is waiting, with retry.
          ValueListenableBuilder<int>(
            valueListenable: OutboxService.instance.pending,
            builder: (context, pending, _) => pending == 0
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Outbox ($pending waiting)',
                    icon: Badge(
                      label: Text('$pending'),
                      backgroundColor: Colors.black,
                      child: const Icon(Icons.outbox_outlined),
                    ),
                    onPressed: _showOutbox,
                  ),
          ),
          // Public feedback on Nostr: read, post, reply, react. The badge
          // counts new replies and reactions to the reader's own feedback.
          ValueListenableBuilder<int>(
            valueListenable: FeedbackService.unseenCount,
            builder: (context, unseen, _) => IconButton(
              tooltip: unseen == 0
                  ? 'Feedback'
                  : 'Feedback ($unseen new)',
              icon: Badge(
                isLabelVisible: unseen > 0,
                label: Text('$unseen'),
                backgroundColor: Colors.black,
                child: const Icon(Icons.forum_outlined),
              ),
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FeedbackScreen())),
            ),
          ),
          // Hidden when there is nothing to sync (no source yet).
          if (_hasSomethingToSync || syncing)
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
          // Tap opens the active profile; long-press switches between
          // profiles or adds one (the last used profile is remembered).
          Builder(
            builder: (iconContext) => GestureDetector(
              onLongPress: () async {
                await showProfileSwitcherMenu(iconContext);
                _load();
              },
              child: IconButton(
                tooltip: 'Profile',
                icon: const Icon(Icons.account_circle_outlined),
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ProfileScreen()));
                  _load();
                },
              ),
            ),
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
        // Once read, a saved article is done: it moves to the Read tab (and
        // comes back here if marked unread).
        return ArticleFeed(
          articles: _articles
              .where((a) => a.readLater == 1 && a.read == 0)
              .toList(),
          sourceTitles: _sourceTitles,
          emptyMessage:
              'Nothing saved to read later.\n\nTap the bookmark '
              'icon on any article in the feed.',
          onChanged: _load,
        );
      case _HomeTab.read:
        // Most recently read first. Articles read before reading times
        // were recorded fall back to their publication date.
        int readTime(Article a) => a.readAt ?? a.publishedAt ?? a.createdAt;
        final readAll = _articles
            .where((a) =>
                a.read == 1 && (!_readFavoritesOnly || a.favorite == 1))
            .toList()
          ..sort((a, b) => readTime(b).compareTo(readTime(a)));
        final readCounts = <int, int>{};
        for (final a in readAll) {
          readCounts[a.sourceId] = (readCounts[a.sourceId] ?? 0) + 1;
        }
        final readSourceId =
            readCounts.containsKey(_readSourceId) ? _readSourceId : null;
        final read = readSourceId == null
            ? readAll
            : readAll.where((a) => a.sourceId == readSourceId).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(width: 1)),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _ReadFilterChip(
                    label: 'All',
                    selected: !_readFavoritesOnly,
                    onTap: () =>
                        setState(() => _readFavoritesOnly = false),
                  ),
                  const SizedBox(width: 8),
                  _ReadFilterChip(
                    label: '★ Favorites',
                    selected: _readFavoritesOnly,
                    onTap: () => setState(() => _readFavoritesOnly = true),
                  ),
                ],
              ),
            ),
            ..._sourceFacetRow(
              counts: readCounts,
              selectedId: readSourceId,
              onSelected: (id) => setState(() => _readSourceId = id),
            ),
            Expanded(
              child: ArticleFeed(
                articles: read,
                dateOf: readTime,
                // Everything here is read: no need to say so on each row.
                showReadMark: false,
                sourceTitles: _sourceTitles,
                emptyMessage: _readFavoritesOnly
                    ? 'No favorites yet.\n\nUse the favorite button at '
                        'the end of an article.'
                    : 'Nothing finished yet.\n\nArticles land here when '
                        'you reach the bottom — or swipe one right in the '
                        'feed to mark it read.',
                rowAction: _readFavoritesOnly
                    ? FeedRowAction.unfavorite
                    : FeedRowAction.readLater,
                onChanged: _load,
              ),
            ),
          ],
        );
      case _HomeTab.highlights:
        // Highlights belong to articles; group them per source so they can
        // be filtered the same way as search results.
        final articleSource = {for (final a in _articles) a.id!: a.sourceId};
        final highlightCounts = <int, int>{};
        for (final h in _highlights) {
          final sourceId = articleSource[h.articleId];
          if (sourceId == null) continue;
          highlightCounts[sourceId] = (highlightCounts[sourceId] ?? 0) + 1;
        }
        final highlightsSourceId =
            highlightCounts.containsKey(_highlightsSourceId)
                ? _highlightsSourceId
                : null;
        final highlights = highlightsSourceId == null
            ? _highlights
            : _highlights
                .where(
                    (h) => articleSource[h.articleId] == highlightsSourceId)
                .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._sourceFacetRow(
              counts: highlightCounts,
              selectedId: highlightsSourceId,
              onSelected: (id) => setState(() => _highlightsSourceId = id),
            ),
            Expanded(
                child:
                    HighlightList(highlights: highlights, onChanged: _load)),
          ],
        );
      case _HomeTab.shared:
        return SharedList(shares: _shares, onChanged: _load);
      case _HomeTab.debug:
        return const _DebugLogView();
    }
  }

  /// Lists what's waiting in the outbox with per-item delete and retry-all.
  Future<void> _showOutbox() async {
    final items = await OutboxService.instance.items();
    if (!mounted) return;
    // A tweet refused for auth reasons says "reconnect Twitter": offer the
    // button right here rather than sending the reader to find it.
    final offerReconnect = items.any((item) =>
        item.kind != 'nostr' &&
        item.kind != 'email' &&
        needsTwitterReconnect(item.lastError));
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: Text('Outbox — ${items.length} waiting'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final item in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(item.kind == 'nostr'
                      ? Icons.cell_tower
                      : Icons.alternate_email),
                  title: Text(item.text,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: item.lastError == null
                      ? null
                      : Text(
                          // Held items were refused for good: retrying
                          // can't help, discarding is the only way out.
                          '${item.held ? 'Not retried' : '${item.attempts} attempt'
                              '${item.attempts == 1 ? '' : 's'}'} · '
                          '${item.lastError!.replaceFirst(RegExp(r'^Exception:\s*'), '')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                  trailing: IconButton(
                    tooltip: 'Discard',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await OutboxService.instance.delete(item.id!);
                      if (dialogContext.mounted) {
                        Navigator.pop(dialogContext);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
          if (offerReconnect)
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'reconnect'),
                child: const Text('Reconnect Twitter')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'retry'),
              child: const Text('Retry now')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'reconnect') {
      // Reconnecting sends the outbox itself once connected.
      await reconnectTwitter(
          messenger: ScaffoldMessenger.of(context),
          navigator: Navigator.of(context));
      return;
    }
    if (choice != 'retry') return;
    final (sent, remaining) = await OutboxService.instance.flush();
    if (!mounted) return;
    showNotice(
        context,
        remaining == 0
            ? 'Outbox sent ($sent item${sent == 1 ? '' : 's'})'
            : 'Sent $sent — $remaining still waiting');
  }

  /// Per-source breakdown chips for the Read and Highlights tabs (mirrors
  /// the search facets): "All" first, then every source with items —
  /// alphabetical, counts shown, zero-count sources absent. Returns an empty
  /// list (no row at all) when everything comes from a single source.
  List<Widget> _sourceFacetRow({
    required Map<int, int> counts,
    required int? selectedId,
    required ValueChanged<int?> onSelected,
  }) {
    if (counts.length < 2) return const [];
    final entries = [
      for (final e in counts.entries)
        (id: e.key, title: _sourceTitles[e.key] ?? 'Unknown', count: e.value)
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final total = counts.values.fold(0, (sum, value) => sum + value);
    return [
      Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(width: 1)),
        ),
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            _SourceChip(
              label: 'All',
              count: total,
              selected: selectedId == null,
              syncing: false,
              onTap: () => onSelected(null),
            ),
            for (final entry in entries) ...[
              const SizedBox(width: 8),
              _SourceChip(
                label: entry.title,
                count: entry.count,
                selected: selectedId == entry.id,
                syncing: false,
                onTap: () => onSelected(entry.id),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// Long-press on a source chip: an options menu anchored under the chip
  /// (Rename, then every folder it can move to), so filing or renaming a
  /// source doesn't need a trip to Settings.
  Future<void> _showSourceChipMenu(int sourceId, Rect chip) async {
    final source = _sources.where((s) => s.id == sourceId).firstOrNull;
    if (source == null) return;
    final folders = [..._folders]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(chip.left, chip.bottom, chip.width, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        // Plain text items: fixed-width Rows overflow while the menu's
        // open/close animation is mid-width.
        for (final folder in folders)
          if (folder.id != source.folderId)
            PopupMenuItem(
              value: '${folder.id}',
              child: Text('Move to "${folder.title}"',
                  overflow: TextOverflow.ellipsis),
            ),
        if (source.folderId != null)
          const PopupMenuItem(value: 'top', child: Text('Move to top level')),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == 'rename') return _renameSource(sourceId);
    final folderId = choice == 'top' ? null : int.parse(choice);
    await _db.setSourceFolder(sourceId, folderId);
    await _load();
  }

  /// Double-tap on a source chip (or Rename in its menu): edit its name in
  /// place. Feeds keep a custom name: refreshing only fills a missing title.
  Future<void> _renameSource(int sourceId) async {
    final source = _sources.where((s) => s.id == sourceId).firstOrNull;
    if (source == null) return;
    final controller = TextEditingController(text: source.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Rename source'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Source name'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    // Not disposed here: the dialog's closing animation still uses it.
    if (title == null || title.isEmpty || title == source.title || !mounted) {
      return;
    }
    await _db.updateSourceTitle(sourceId, title);
    await _load();
  }

  /// The Add source screen covers every kind (RSS, Twitter, Nostr).
  Future<void> _openAddSource() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AddSourceScreen()));
    _load();
  }

  /// The suggested-reads picker, for readers who'd like to see the app
  /// with something in it before adding their own sources.
  Future<void> _addSuggestedSources() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const SuggestedSourcesScreen()));
    await _load();
    // The feeds land over the next seconds; refresh as they do.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _load();
    });
  }

  bool _reconnectingTwitter = false;

  /// Re-runs the Twitter OAuth flow right from the feed's error banner (the
  /// client id from the original connection is remembered), then refreshes
  /// the source. Falls back to the Add source screen when no client id is
  /// stored on this install.
  Future<void> _reconnectTwitter(Source source) async {
    if (_reconnectingTwitter) return;
    setState(() => _reconnectingTwitter = true);
    try {
      final connected = await reconnectTwitter(
          messenger: ScaffoldMessenger.of(context),
          navigator: Navigator.of(context));
      if (!connected) return;
      SyncService.instance.sourceErrors.remove(source.id);
      if (mounted) setState(() {});
      await SyncService.instance.syncSources([source]);
      await _load();
    } finally {
      if (mounted) setState(() => _reconnectingTwitter = false);
    }
  }

  /// Marks [ids] as seen, with an Undo in case the tap was a slip.
  Future<void> _markSeen(List<int> ids) async {
    await _db.markArticlesSeen(ids);
    await _load();
    if (!mounted) return;
    showNotice(
      context,
      ids.length == 1
          ? '1 article marked as seen'
          : '${ids.length} articles marked as seen',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          await _db.markArticlesSeen(ids, seen: false);
          _load();
        },
      ),
    );
  }

  /// Feed tab: a swipable filter strip above the article list — "All" first,
  /// then folders, then top-level sources, each group alphabetical. A stable
  /// order preserves the reader's spatial memory of where each chip lives.
  /// Tapping a source filters the feed to it; tapping a folder opens a menu
  /// with the whole folder and its sources. With no sources configured yet, a
  /// centered call-to-action replaces the feed.
  Widget _buildFeed() {
    if (!_everLoaded) return const SizedBox.shrink();
    final total = <int, int>{};
    final unread = <int, int>{};
    for (final article in _articles) {
      total[article.sourceId] = (total[article.sourceId] ?? 0) + 1;
      if (article.isNew) {
        unread[article.sourceId] = (unread[article.sourceId] ?? 0) + 1;
      }
    }
    // The always-present Inbox alone doesn't count as "has sources".
    final inboxId = _inboxSourceId;
    if (_sourceTitles.keys.every((id) => id == inboxId) &&
        !total.containsKey(inboxId)) {
      return _EmptySourcesView(
          onAdd: _openAddSource, onSuggested: _addSuggestedSources);
    }
    int compareFilters(_SourceFilter a, _SourceFilter b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());

    _SourceFilter filterFor(int id) => _SourceFilter(
          id: id,
          title: _sourceTitles[id] ?? 'Unknown',
          unread: unread[id] ?? 0,
          total: total[id] ?? 0,
        );

    final folderOf = {for (final s in _sources) s.id!: s.folderId};
    final topSources = {
      ...total.keys,
      if (inboxId != null) inboxId,
    }.where((id) => folderOf[id] == null).map(filterFor).toList()
      ..sort(compareFilters);
    // The Inbox leads, right after All (before folders); the rest stay
    // alphabetical.
    final inboxFilter =
        topSources.where((f) => f.id == inboxId).firstOrNull;
    if (inboxFilter != null) topSources.remove(inboxFilter);

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
    folders.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    // Fall back to "All" if the selection no longer has any articles.
    final selectedId =
        total.containsKey(_feedSourceId) || _feedSourceId == inboxId
            ? _feedSourceId
            : null;
    final selectedFolderId =
        folders.any((f) => f.id == _feedFolderId) ? _feedFolderId : null;
    var articles = selectedFolderId != null
        ? _articles
            .where((a) => folderOf[a.sourceId] == selectedFolderId)
            .toList()
        : selectedId == null
            ? _articles
            : _articles.where((a) => a.sourceId == selectedId).toList();

    // A Twitter source is a folder of accounts: selecting it reveals a
    // second chip row with every bookmarked author, alphabetical.
    List<_AuthorFilter>? authorRow;
    final selectedSource = selectedId == null
        ? null
        : _sources.where((s) => s.id == selectedId).firstOrNull;
    // The Inbox likewise gets a row of senders.
    final isInbox = selectedSource?.type == SourceType.email;
    if (selectedSource != null &&
        (selectedSource.type == SourceType.twitterBookmarks || isInbox)) {
      final byAuthor = <String, ({int unread, int total})>{};
      for (final article in articles) {
        final author = article.author;
        if (author == null || author.isEmpty) continue;
        final counts =
            byAuthor[author] ?? (unread: 0, total: 0);
        byAuthor[author] = (
          unread: counts.unread + (article.isNew ? 1 : 0),
          total: counts.total + 1,
        );
      }
      // With many one-off accounts the strip gets noisy: past 10 authors,
      // only those with 2+ bookmarks keep a chip; the rest collapse into
      // a trailing "Others".
      var entries = byAuthor.entries.toList();
      var othersSet = <String>{};
      if (entries.length > 10) {
        othersSet = {
          for (final e in entries.where((e) => e.value.total < 2)) e.key
        };
        entries =
            entries.where((e) => e.value.total >= 2).toList();
      }
      // Twitter accounts are alphabetical; Inbox senders come by how much
      // they sent (most first), ties alphabetical.
      entries.sort((a, b) {
        if (isInbox && a.value.total != b.value.total) {
          return b.value.total.compareTo(a.value.total);
        }
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
      authorRow = [
        for (final entry in entries)
          _AuthorFilter(
              name: entry.key,
              label: entry.key,
              unread: entry.value.unread)
      ];
      if (othersSet.isNotEmpty) {
        authorRow.add(_AuthorFilter(
          name: _othersAuthor,
          label: 'Others',
          unread: othersSet.fold(
              0, (sum, name) => sum + (byAuthor[name]?.unread ?? 0)),
        ));
      }
      final requests = SyncService.instance.emailRequests;
      if (isInbox && requests.isNotEmpty) {
        authorRow.add(_AuthorFilter(
          name: _requestsAuthor,
          label: 'Other senders',
          unread: requests.length,
        ));
      }
      final selectedAuthor = _feedAuthor;
      if (selectedAuthor == _requestsAuthor && isInbox && requests.isNotEmpty) {
        // Requests aren't articles yet: the header lists them.
        articles = const [];
      } else if (selectedAuthor == _othersAuthor && othersSet.isNotEmpty) {
        articles =
            articles.where((a) => othersSet.contains(a.author)).toList();
      } else if (selectedAuthor != null &&
          authorRow.any((a) => a.name == selectedAuthor)) {
        articles =
            articles.where((a) => a.author == selectedAuthor).toList();
      }
    }
    final allUnread = unread.values.fold(0, (sum, value) => sum + value);

    // Resume reading obeys the chip filters: computed from the filtered
    // list, so selecting a source/folder/author narrows it too.
    final currentReads = ResumeReadingSection.currentReads(articles);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SourceFilterBar(
          inbox: inboxFilter,
          folders: folders,
          sources: topSources,
          selectedId: selectedId,
          selectedFolderId: selectedFolderId,
          allUnread: allUnread,
          syncingSourceIds: _syncingSourceIds,
          errorSourceIds: SyncService.instance.sourceErrors.keys.toSet(),
          authors: authorRow,
          selectedAuthor: _feedAuthor,
          onAuthorSelected: (author) =>
              setState(() => _feedAuthor = author),
          onSelected: (id) => setState(() {
            _feedSourceId = id;
            _feedFolderId = null;
            _feedAuthor = null;
          }),
          onFolderTap: (folder) => setState(() {
            _feedFolderId = folder.id;
            _feedSourceId = null;
            _feedAuthor = null;
          }),
          onSourceLongPress: _showSourceChipMenu,
          onSourceDoubleTap: _renameSource,
        ),
        // The selected source's last refresh failed: say why above its feed,
        // and — when the error is an auth problem that reconnecting actually
        // fixes (not, say, depleted API credits) — offer to reconnect the
        // Twitter account right here.
        if (selectedSource != null &&
            SyncService.instance.sourceErrors.containsKey(selectedSource.id))
          _SourceErrorBanner(
            message: SyncService.instance.sourceErrors[selectedSource.id]!,
            busy: _reconnectingTwitter,
            onReconnect: selectedSource.type == SourceType.twitterBookmarks &&
                    needsTwitterReconnect(
                        SyncService.instance.sourceErrors[selectedSource.id])
                ? () => _reconnectTwitter(selectedSource)
                : null,
          ),
        if (isInbox)
          InboxHeader(
            // A new header when switching views, so it reloads.
            key: ValueKey('inbox-${_feedAuthor == _requestsAuthor}'),
            onChanged: _load,
            showRequests: _feedAuthor == _requestsAuthor &&
                SyncService.instance.emailRequests.isNotEmpty,
          ),
        // Catching up without pretending to have read: marks what this view
        // shows (all, a folder, a source or an author) as seen, so the
        // chips and bold titles only flag what arrives next.
        if (articles.any((a) => a.isNew))
          _MarkSeenBar(
            count: articles.where((a) => a.isNew).length,
            onPressed: () => _markSeen(
                [for (final a in articles) if (a.isNew) a.id!]),
          ),
        if (currentReads.isNotEmpty)
          ResumeReadingSection(
            articles: currentReads,
            sourceTitles: _sourceTitles,
            onChanged: _load,
          ),
        Expanded(
          child: ArticleFeed(
            articles: articles,
            sourceTitles: _sourceTitles,
            emptyMessage: isInbox
                ? (_feedAuthor == _requestsAuthor &&
                        SyncService.instance.emailRequests.isNotEmpty
                    ? ''
                    : 'Nothing in your Inbox yet.')
                : 'No articles yet.\n\nPull to sync, or manage sources '
                    'in Settings.',
            onChanged: _load,
            onShown: (article) => _shownIds.add(article.id!),
          ),
        ),
      ],
    );
  }
}

/// Centered call-to-action shown on the Feed tab when no sources exist yet.
class _EmptySourcesView extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onSuggested;

  const _EmptySourcesView({required this.onAdd, required this.onSuggested});

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
            const SizedBox(height: 12),
            TextButton(
              onPressed: onSuggested,
              child: const Text(
                'Or start with suggested reads',
                style: TextStyle(
                    fontSize: 16, decoration: TextDecoration.underline),
              ),
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

/// One author inside a Twitter source's second-row strip. [name] is the
/// filter key (a sentinel for "Others"); [label] is what the chip shows.
class _AuthorFilter {
  final String name;
  final String label;
  final int unread;
  const _AuthorFilter(
      {required this.name, required this.label, required this.unread});
}

/// Horizontally swipable strip of filter chips shown above the feed: "All"
/// first, then folders, then top-level sources (both supplied ordered).
/// Tapping a folder selects it and reveals a second row below with the
/// folder's sources; a Twitter source likewise reveals a row of the
/// bookmarked accounts.
class _SourceFilterBar extends StatelessWidget {
  /// The Inbox chip, placed first after "All" (before folders).
  final _SourceFilter? inbox;
  final List<_FolderFilter> folders;
  final List<_SourceFilter> sources;
  final int? selectedId;
  final int? selectedFolderId;
  final int allUnread;
  final Set<int> syncingSourceIds;

  /// Sources whose last refresh failed — their chips carry a warning icon.
  final Set<int> errorSourceIds;
  final ValueChanged<int?> onSelected;
  final ValueChanged<_FolderFilter> onFolderTap;

  /// Long-press on a source chip (top row or a folder's row), with the
  /// chip's global rect to anchor the options menu.
  final void Function(int sourceId, Rect chip)? onSourceLongPress;

  /// Double-tap on a source chip: rename it.
  final ValueChanged<int>? onSourceDoubleTap;

  /// Author strip for a selected Twitter source (null = no second row).
  final List<_AuthorFilter>? authors;
  final String? selectedAuthor;
  final ValueChanged<String?> onAuthorSelected;

  const _SourceFilterBar({
    this.inbox,
    required this.folders,
    required this.sources,
    required this.selectedId,
    required this.selectedFolderId,
    required this.allUnread,
    required this.syncingSourceIds,
    required this.errorSourceIds,
    required this.onSelected,
    required this.onFolderTap,
    this.onSourceLongPress,
    this.onSourceDoubleTap,
    this.authors,
    this.selectedAuthor,
    required this.onAuthorSelected,
  });

  /// The folder whose sources show in the second row: the selected one, or
  /// the one containing the selected source (which has no top-row chip).
  _FolderFilter? get _activeFolder {
    for (final folder in folders) {
      if (selectedFolderId == folder.id ||
          folder.members.any((m) => m.id == selectedId)) {
        return folder;
      }
    }
    return null;
  }

  Widget _chipRow(List<Widget> chips) => SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              chips[i],
            ],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final activeFolder = _activeFolder;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: Column(
        children: [
          _chipRow([
            _SourceChip(
              label: 'All',
              count: allUnread,
              selected: selectedId == null && selectedFolderId == null,
              syncing: false,
              onTap: () => onSelected(null),
            ),
            if (inbox != null)
              _SourceChip(
                label: inbox!.title,
                count: inbox!.unread,
                selected: selectedId == inbox!.id,
                syncing: syncingSourceIds.contains(inbox!.id),
                error: errorSourceIds.contains(inbox!.id),
                onTap: () => onSelected(inbox!.id),
              ),
            for (final folder in folders)
              _SourceChip(
                label: folder.title,
                icon: Icons.folder_outlined,
                count: folder.unread,
                // Selected for the folder itself or a source inside it,
                // whose chip lives in the second row.
                selected: selectedFolderId == folder.id ||
                    folder.members.any((m) => m.id == selectedId),
                syncing: folder.members
                    .any((m) => syncingSourceIds.contains(m.id)),
                error: folder.members
                    .any((m) => errorSourceIds.contains(m.id)),
                onTap: () => onFolderTap(folder),
              ),
            for (final source in sources)
              _SourceChip(
                label: source.title,
                count: source.unread,
                selected: selectedId == source.id,
                syncing: syncingSourceIds.contains(source.id),
                error: errorSourceIds.contains(source.id),
                onTap: () => onSelected(source.id),
                onLongPress: onSourceLongPress == null
                    ? null
                    : (rect) => onSourceLongPress!(source.id, rect),
                onDoubleTap: onSourceDoubleTap == null
                    ? null
                    : () => onSourceDoubleTap!(source.id),
              ),
          ]),
          if (activeFolder != null) ...[
            const Divider(height: 1),
            _chipRow([
              for (final member in activeFolder.members)
                _SourceChip(
                  label: member.title,
                  count: member.unread,
                  selected: selectedId == member.id,
                  syncing: syncingSourceIds.contains(member.id),
                  error: errorSourceIds.contains(member.id),
                  onTap: () => onSelected(member.id),
                  onLongPress: onSourceLongPress == null
                      ? null
                      : (rect) => onSourceLongPress!(member.id, rect),
                  onDoubleTap: onSourceDoubleTap == null
                      ? null
                      : () => onSourceDoubleTap!(member.id),
                ),
            ]),
          ],
          if (authors != null && authors!.isNotEmpty) ...[
            const Divider(height: 1),
            _chipRow([
              _SourceChip(
                label: 'All',
                count: authors!.fold(0, (sum, a) => sum + a.unread),
                selected: selectedAuthor == null,
                syncing: false,
                onTap: () => onAuthorSelected(null),
              ),
              for (final author in authors!)
                _SourceChip(
                  label: author.label,
                  count: author.unread,
                  selected: selectedAuthor == author.name,
                  syncing: false,
                  onTap: () => onAuthorSelected(author.name),
                ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// Slim row above the feed offering to mark its new articles as seen.
/// Seen is not read: they lose their bold and their count on the chips, but
/// stay out of the Read tab, which keeps listing only what was read.
class _MarkSeenBar extends StatelessWidget {
  final int count;
  final VoidCallback onPressed;

  const _MarkSeenBar({required this.count, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == 1 ? '1 new article' : '$count new articles',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.done_all, size: 20),
            label: const Text(
              'Mark all as seen',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }
}

/// Flat, e-ink friendly pill: solid black when selected, outlined otherwise,
/// with a trailing unread count when there is one.
class _SourceChip extends StatefulWidget {
  final String label;
  final int count;
  final bool selected;

  /// Optional leading icon (folders show a folder glyph).
  final IconData? icon;

  /// While true, a spinner replaces the unread count to show this source is
  /// being updated.
  final bool syncing;

  /// True when the source's last refresh failed: a warning icon tells the
  /// reader to tap the chip and see (and fix) the error above the feed.
  final bool error;
  final VoidCallback onTap;

  /// Long-press, given the chip's global rect (to anchor a menu under it).
  final ValueChanged<Rect>? onLongPress;
  final VoidCallback? onDoubleTap;

  const _SourceChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.syncing,
    required this.onTap,
    this.error = false,
    this.icon,
    this.onLongPress,
    this.onDoubleTap,
  });

  @override
  State<_SourceChip> createState() => _SourceChipState();
}

class _SourceChipState extends State<_SourceChip> {
  /// Running while a second tap would count as a double-tap. A plain
  /// onDoubleTap would hold every single tap back ~300 ms to rule one out;
  /// here the first tap selects at once and a quick second one renames.
  Timer? _doubleTapWindow;

  @override
  void dispose() {
    _doubleTapWindow?.cancel();
    super.dispose();
  }

  void _handleTap() {
    final onDoubleTap = widget.onDoubleTap;
    if (onDoubleTap != null && (_doubleTapWindow?.isActive ?? false)) {
      _doubleTapWindow!.cancel();
      onDoubleTap();
      return;
    }
    if (onDoubleTap != null) {
      _doubleTapWindow = Timer(kDoubleTapTimeout, () {});
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final icon = widget.icon;
    final label = widget.label;
    final count = widget.count;
    final foreground = selected ? Colors.white : Colors.black;
    final onLongPress = widget.onLongPress;
    return InkWell(
      onTap: _handleTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              final box = context.findRenderObject() as RenderBox;
              onLongPress(box.localToGlobal(Offset.zero) & box.size);
            },
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
            if (widget.error) ...[
              Icon(Icons.warning_amber_rounded, size: 16, color: foreground),
              const SizedBox(width: 6),
            ],
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
            if (widget.syncing) ...[
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

/// Shown above a source's feed when its last refresh failed: what went
/// wrong, and — for a Twitter source — a button that reconnects the account
/// on the spot instead of sending the reader hunting through Settings.
class _SourceErrorBanner extends StatelessWidget {
  final String message;
  final bool busy;

  /// Null for sources with no in-place fix (the message alone still helps).
  final VoidCallback? onReconnect;

  const _SourceErrorBanner({
    required this.message,
    required this.busy,
    this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.warning_amber_rounded, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'This source could not refresh: $message',
                  style: const TextStyle(fontSize: 14, height: 1.35),
                ),
              ),
            ],
          ),
          if (onReconnect != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: busy ? null : onReconnect,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(width: 1.5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              ),
              child: Text(
                busy ? 'Reconnecting…' : 'Reconnect Twitter',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
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
  final _searchController = TextEditingController();
  String _query = '';

  /// Warnings and errors only: the entries worth reading when something
  /// failed, without the routine sync chatter around them.
  bool _problemsOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = AppLogService.instance.changes.stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchController.dispose();
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
    // Case-insensitive substring filter, e.g. "twitter" for the whole story
    // of a post attempt.
    final query = _query.trim().toLowerCase();
    final visible = _entries
        .where((e) =>
            (!_problemsOnly || e.level == 'warn' || e.level == 'error') &&
            (query.isEmpty || e.message.toLowerCase().contains(query)))
        .toList();
    final filtered = query.isNotEmpty || _problemsOnly;
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _ReadFilterChip(
                label: 'Problems',
                selected: _problemsOnly,
                onTap: () => setState(() => _problemsOnly = !_problemsOnly),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search logs… (e.g. twitter)',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _query.isEmpty
                        ? const Icon(Icons.search)
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                !filtered
                    ? '${_entries.length}'
                    : '${visible.length}/${_entries.length}',
                style:
                    const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
              ),
              const SizedBox(width: 8),
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
            itemCount: visible.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = visible[index];
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

/// Flat pill used by the Read tab's All / ★ Favorites filter.
class _ReadFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReadFilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.black : Colors.white,
          border: Border.all(width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.black)),
      ),
    );
  }
}
