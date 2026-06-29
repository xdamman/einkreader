import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/article_screen.dart';
import '../services/archive_store.dart';

/// All saved highlights, newest first. Tapping one opens its article;
/// a long-press deletes it.
class HighlightList extends StatelessWidget {
  final List<Highlight> highlights;
  final VoidCallback onChanged;

  const HighlightList({
    super.key,
    required this.highlights,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (highlights.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No highlights yet.\n\nSelect text while reading and choose '
            '"Highlight" to save it here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: highlights.length,
      separatorBuilder: (_, __) => const Divider(),
      itemBuilder: (context, index) => _tile(context, highlights[index]),
    );
  }

  Widget _tile(BuildContext context, Highlight highlight) {
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
        onChanged();
      },
      onLongPress: () => _confirmDelete(context, highlight),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, Highlight highlight) async {
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
      await AppDatabase.instance.deleteHighlight(highlight.id!);
      await ArchiveStore.instance
          .writeHighlights(await AppDatabase.instance.getHighlights());
      onChanged();
    }
  }
}
