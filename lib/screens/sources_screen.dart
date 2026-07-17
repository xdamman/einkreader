import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'add_source_screen.dart';
import 'article_list_screen.dart';

/// Manage sources and their folders (one level): folders come first with
/// their sources indented, then top-level sources. Add RSS feeds and folders
/// below; long-press a source to move it into a folder or remove it. Folders
/// are renamed/removed via their trailing icons. Twitter/Nostr sources are
/// added from Settings.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sources = await _db.getSources();
    final folders = await _db.getFolders();
    final unread = await _db.unreadCountsBySource();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _folders = folders;
      _unread = unread;
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
    // Folders first (each with its sources indented), then top-level sources.
    final entries = <Widget>[];
    for (final folder in _folders) {
      final members =
          _sources.where((s) => s.folderId == folder.id).toList();
      entries.add(_folderTile(folder, members));
      for (final source in members) {
        entries.add(_sourceTile(source, indented: true));
      }
    }
    for (final source in _sources.where((s) => s.folderId == null)) {
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

  Widget _folderTile(Folder folder, List<Source> members) {
    final unread =
        members.fold(0, (sum, s) => sum + (_unread[s.id] ?? 0));
    return ListTile(
      key: ValueKey('folder-${folder.id}'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(folder.title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      subtitle: Text(
          '${members.length} source${members.length == 1 ? '' : 's'}'
          '${unread > 0 ? ' · $unread unread' : ''}',
          style: const TextStyle(fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Rename folder',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _renameFolder(folder),
          ),
          IconButton(
            tooltip: 'Remove folder',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteFolder(folder, members),
          ),
        ],
      ),
    );
  }

  Widget _sourceTile(Source source, {required bool indented}) {
    final unread = _unread[source.id] ?? 0;
    return ListTile(
      key: ValueKey('source-${source.id}'),
      contentPadding:
          EdgeInsets.only(left: indented ? 40 : 16, right: 16),
      leading: Icon(_iconFor(source.type)),
      title: Text(source.title, style: const TextStyle(fontSize: 17)),
      subtitle:
          Text(source.type.label, style: const TextStyle(fontSize: 13)),
      trailing: unread > 0
          ? Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(border: Border.all()),
              child: Text('$unread',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            )
          : null,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleListScreen(source: source)));
        _load();
      },
      onLongPress: () => _showSourceMenu(source),
    );
  }

  /// Long-press menu for a source: move it into/out of a folder, or remove.
  Future<void> _showSourceMenu(Source source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(source.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Move to folder…'),
              onTap: () => Navigator.pop(sheetContext, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'move') {
      await _moveToFolder(source);
    } else if (action == 'remove') {
      await _confirmDelete(source);
    }
  }

  Future<void> _moveToFolder(Source source) async {
    // Sentinel for "top level", since null is the sheet's dismissal.
    const topLevel = -1;
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: Icon(source.folderId == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: const Text('Top level (no folder)'),
              onTap: () => Navigator.pop(sheetContext, topLevel),
            ),
            for (final folder in _folders)
              ListTile(
                leading: Icon(source.folderId == folder.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off),
                title: Text(folder.title),
                onTap: () => Navigator.pop(sheetContext, folder.id),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    await _db.setSourceFolder(source.id!, choice == topLevel ? null : choice);
    _load();
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
