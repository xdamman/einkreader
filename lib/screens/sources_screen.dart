import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'add_source_screen.dart';
import 'article_list_screen.dart';

/// Manage sources and their folders (one level): folders come first with
/// their sources indented, then top-level sources. Add RSS feeds and folders
/// below. Each source row shows the feed's description (when its XML
/// provides one) and stats, and has an anchored ⋮ menu — kept next to its
/// trigger so it also works on tablets, unlike a bottom sheet — that lists
/// the folders to move to directly. Sources can also be dragged onto a
/// folder (long-press, then drag). Twitter/Nostr sources are added from
/// Settings.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _db = AppDatabase.instance;
  List<Source> _sources = [];
  List<Folder> _folders = [];
  Map<int, int> _unread = {};
  Map<int, SourceStats> _stats = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = await _db.getSources();
    final folders = await _db.getFolders();
    final unread = await _db.unreadCountsBySource();
    final stats = await _db.sourceStats();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _folders = folders;
      _unread = unread;
      _stats = stats;
    });
  }

  IconData _iconFor(SourceType type) => switch (type) {
        SourceType.rss => Icons.rss_feed,
        SourceType.twitterBookmarks => Icons.bookmark_outline,
        SourceType.twitterLikes => Icons.favorite_outline,
        SourceType.nostrBookmarks => Icons.bookmark_outline,
        SourceType.nostrLikes => Icons.favorite_outline,
        SourceType.savedLinks => Icons.link,
      };

  @override
  Widget build(BuildContext context) {
    // Folders first (each with its sources indented), then top-level sources;
    // everything alphabetical so the list keeps a stable, memorable layout.
    final sorted = [..._sources]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final entries = <Widget>[];
    for (final folder in _folders) {
      final members = sorted.where((s) => s.folderId == folder.id).toList();
      entries.add(_folderTile(folder, members));
      for (final source in members) {
        entries.add(_sourceTile(source, indented: true));
      }
    }
    for (final source in sorted.where((s) => s.folderId == null)) {
      entries.add(_sourceTile(source, indented: false));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: entries.isEmpty
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
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) => entries[index],
                  ),
          ),
          const Divider(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Add folder'),
                      onPressed: _addFolder,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A folder row is also a drop target: drag a source onto it to file it.
  Widget _folderTile(Folder folder, List<Source> members) {
    final unread =
        members.fold(0, (sum, s) => sum + (_unread[s.id] ?? 0));
    return DragTarget<Source>(
      key: ValueKey('folder-${folder.id}'),
      onWillAcceptWithDetails: (details) =>
          details.data.folderId != folder.id,
      onAcceptWithDetails: (details) async {
        await _db.setSourceFolder(details.data.id!, folder.id);
        _load();
      },
      builder: (context, candidates, rejected) => Container(
        // Invert while a dragged source hovers, so the target is obvious.
        color: candidates.isNotEmpty ? Colors.black : null,
        child: ListTile(
          leading: Icon(Icons.folder_outlined,
              color: candidates.isNotEmpty ? Colors.white : Colors.black),
          textColor: candidates.isNotEmpty ? Colors.white : Colors.black,
          title: Text(folder.title,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          subtitle: Text(
              '${members.length} source${members.length == 1 ? '' : 's'}'
              '${unread > 0 ? ' · $unread unread' : ''}',
              style: const TextStyle(fontSize: 13)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Rename folder',
                icon: Icon(Icons.edit_outlined,
                    color:
                        candidates.isNotEmpty ? Colors.white : Colors.black),
                onPressed: () => _renameFolder(folder),
              ),
              IconButton(
                tooltip: 'Remove folder',
                icon: Icon(Icons.delete_outline,
                    color:
                        candidates.isNotEmpty ? Colors.white : Colors.black),
                onPressed: () => _deleteFolder(folder, members),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "1.2 MB"-style size for the stats line.
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _sourceTile(Source source, {required bool indented}) {
    final unread = _unread[source.id] ?? 0;
    final stats = _stats[source.id] ?? const SourceStats();
    final statsLine = [
      '${stats.downloaded} article${stats.downloaded == 1 ? '' : 's'}',
      _formatBytes(stats.contentBytes),
      '${stats.read} read',
      if (stats.highlights > 0)
        '${stats.highlights} highlight${stats.highlights == 1 ? '' : 's'}',
    ].join(' · ');

    final tile = ListTile(
      contentPadding:
          EdgeInsets.only(left: indented ? 40 : 16, right: 16),
      leading: Icon(_iconFor(source.type)),
      title: Text(source.title, style: const TextStyle(fontSize: 17)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source.description != null && source.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(source.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontStyle: FontStyle.italic)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(statsLine, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(border: Border.all()),
              child: Text('$unread',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          _sourceMenu(source),
        ],
      ),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleListScreen(source: source)));
        _load();
      },
    );

    // Long-press starts a drag; drop it on a folder row to file it there.
    return LongPressDraggable<Source>(
      key: ValueKey('source-${source.id}'),
      data: source,
      feedback: Material(
        color: Colors.black,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(source.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
    );
  }

  /// Anchored options menu (⋮): opens next to its trigger — a bottom sheet
  /// would put the choices a tablet's height away — and lists the move
  /// destinations directly, saving the "Move to folder…" hop.
  Widget _sourceMenu(Source source) {
    return PopupMenuButton<String>(
      tooltip: 'Source options',
      icon: const Icon(Icons.more_vert),
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      onSelected: (choice) async {
        if (choice == 'remove') {
          await _confirmDelete(source);
          return;
        }
        await _db.setSourceFolder(
            source.id!, choice == 'top' ? null : int.parse(choice));
        _load();
      },
      itemBuilder: (context) => [
        // Plain text items: fixed-width Rows overflow while the menu's
        // open/close animation is mid-width.
        for (final folder in _folders)
          if (folder.id != source.folderId)
            PopupMenuItem(
              value: '${folder.id}',
              child: Text('Move to "${folder.title}"',
                  overflow: TextOverflow.ellipsis),
            ),
        if (source.folderId != null)
          const PopupMenuItem(
            value: 'top',
            child: Text('Move to top level'),
          ),
        if (_folders.isNotEmpty || source.folderId != null)
          const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'remove',
          child: Text('Remove'),
        ),
      ],
    );
  }

  Future<void> _addFolder() async {
    final title = await _promptForTitle('New folder');
    if (title == null || title.isEmpty) return;
    await _db.insertFolder(title);
    _load();
  }

  Future<void> _renameFolder(Folder folder) async {
    final title = await _promptForTitle('Rename folder', initial: folder.title);
    if (title == null || title.isEmpty || title == folder.title) return;
    await _db.renameFolder(folder.id!, title);
    _load();
  }

  Future<String?> _promptForTitle(String prompt, {String? initial}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: Text(prompt),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
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
  }

  Future<void> _deleteFolder(Folder folder, List<Source> members) async {
    // 'move' keeps the sources (moved to top level, the default);
    // 'delete' removes them and their articles too.
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: Text('Remove folder "${folder.title}"?'),
        content: Text(members.isEmpty
            ? 'The folder is empty.'
            : 'It contains ${members.length} '
                'source${members.length == 1 ? '' : 's'}. Move '
                '${members.length == 1 ? 'it' : 'them'} to the top level, '
                'or delete ${members.length == 1 ? 'it' : 'them'} along '
                'with downloaded articles and highlights?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          if (members.isEmpty)
            TextButton(
                onPressed: () => Navigator.pop(context, 'move'),
                child: const Text('Remove'))
          else ...[
            TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: const Text('Delete sources too')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'move'),
                child: const Text('Move to top level',
                    style: TextStyle(fontWeight: FontWeight.w700))),
          ],
        ],
      ),
    );
    if (!mounted || choice == null) return;
    await _db.deleteFolder(folder.id!, deleteSources: choice == 'delete');
    _load();
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
