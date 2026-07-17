import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/article_screen.dart';
import '../services/archive_store.dart';
import '../services/share_actions.dart';

/// All saved highlights, newest first. Tapping one opens its article, the
/// trailing button shares it (email / Twitter / system sheet); a long-press
/// deletes it.
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
      trailing: IconButton(
        tooltip: 'Share highlight',
        icon: const Icon(Icons.share_outlined),
        onPressed: () => _share(context, highlight),
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

  Future<void> _share(BuildContext context, Highlight highlight) async {
    final article =
        await AppDatabase.instance.getArticle(highlight.articleId);
    if (article == null || !context.mounted) return;
    final twitterConnected = await ShareActions.twitterConnected();
    if (!context.mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Share by email'),
              onTap: () => Navigator.pop(sheetContext, 'email'),
            ),
            if (twitterConnected)
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('Share on Twitter'),
                onTap: () => Navigator.pop(sheetContext, 'twitter'),
              ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share…'),
              onTap: () => Navigator.pop(sheetContext, 'share'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final body = ShareActions.highlightsBody(article, [highlight]);
    switch (action) {
      case 'email':
        await ShareActions.byEmail(context,
            subject: ShareActions.highlightsSubject(article, 1), body: body);
      case 'twitter':
        await ShareActions.onTwitter(context, draft: body);
      case 'share':
        await Share.share(body);
    }
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
