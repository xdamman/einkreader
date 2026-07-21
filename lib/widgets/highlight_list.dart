import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/article_screen.dart';
import '../services/archive_store.dart';
import '../services/profile_service.dart';
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              highlight.text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, height: 1.4),
            ),
            if ((highlight.comment ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  highlight.comment!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      height: 1.35),
                ),
              ),
          ],
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
      // Builder: the menu anchors to this button's own context, so it opens
      // next to its trigger instead of a tablet-height away in a bottom sheet.
      trailing: Builder(
        builder: (buttonContext) => IconButton(
          tooltip: 'Share highlight',
          icon: const Icon(Icons.share_outlined),
          onPressed: () => _share(buttonContext, highlight),
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

  Future<void> _share(BuildContext context, Highlight highlight) async {
    // Anchor the menu at the share button (see the Builder in _tile);
    // measured before any await, while the context is synchronously valid.
    final button = context.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final article =
        await AppDatabase.instance.getArticle(highlight.articleId);
    if (article == null || !context.mounted) return;
    final twitterConnected = await ShareActions.twitterConnected();
    final profileEnabled = await ProfileService.instance.enabled;
    if (!context.mounted) return;
    final action = await showMenu<String>(
      context: context,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      position: position,
      items: [
        if (profileEnabled)
          const PopupMenuItem(
              value: 'profile', child: Text('Share to profile')),
        const PopupMenuItem(value: 'email', child: Text('Share by email')),
        if (twitterConnected)
          const PopupMenuItem(
              value: 'twitter', child: Text('Share on Twitter')),
        const PopupMenuItem(value: 'share', child: Text('Share…')),
      ],
    );
    if (action == null || !context.mounted) return;
    final body = ShareActions.highlightsBody(article, [highlight]);
    switch (action) {
      case 'profile':
        String message;
        try {
          final accepted = await ProfileService.instance
              .publishHighlight(article, highlight);
          message = accepted > 0
              ? 'Shared to your profile'
              : 'Sharing failed — try again when online';
        } catch (e) {
          message = 'Sharing failed: $e';
        }
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      case 'email':
        await ShareActions.byEmail(context,
            subject: ShareActions.highlightsSubject(article, 1), body: body);
      case 'twitter':
        await ShareActions.tweetHighlights(context, article, [highlight]);
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
