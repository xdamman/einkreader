import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'article_screen.dart';

/// All saved highlights across every article, newest first.
/// Tapping one opens the article it came from.
class HighlightsScreen extends StatefulWidget {
  const HighlightsScreen({super.key});

  @override
  State<HighlightsScreen> createState() => _HighlightsScreenState();
}

class _HighlightsScreenState extends State<HighlightsScreen> {
  final _db = AppDatabase.instance;
  List<Highlight> _highlights = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final highlights = await _db.getHighlights();
    if (!mounted) return;
    setState(() {
      _highlights = highlights;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Highlights')),
      body: _loading
          ? const SizedBox.shrink()
          : _highlights.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No highlights yet.\n\nSelect text while reading and '
                      'choose "Highlight" to save it here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _highlights.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) =>
                      _highlightTile(_highlights[index]),
                ),
    );
  }

  Widget _highlightTile(Highlight highlight) {
    final date = DateFormat.yMMMd()
        .format(DateTime.fromMillisecondsSinceEpoch(highlight.createdAt));
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(width: 3)),
        ),
        child: Text(
          highlight.text,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, height: 1.4),
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6, left: 15),
        child: Text(
          '${highlight.articleTitle ?? 'Unknown article'} · $date',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
      ),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(
                articleId: highlight.articleId,
                focusHighlight: highlight.text)));
        _load();
      },
      onLongPress: () => _confirmDelete(highlight),
    );
  }

  Future<void> _confirmDelete(Highlight highlight) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Delete highlight?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await _db.deleteHighlight(highlight.id!);
      _load();
    }
  }
}
