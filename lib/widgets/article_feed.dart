import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/article_screen.dart';
import '../services/sync_service.dart';

/// Per-row action shown on the trailing edge of a feed tile.
enum FeedRowAction {
  /// Bookmark toggle that saves the article to the To Read tab.
  readLater,

  /// Filled star that removes the article from Favorites.
  unfavorite,
}

/// Article list grouped by day with date subheadings and a per-row action.
/// Used by the Feed, To Read and Favorites tabs and the per-source list.
class ArticleFeed extends StatelessWidget {
  final List<Article> articles;

  /// Source id → source title, shown in each row's meta line.
  final Map<int, String> sourceTitles;
  final String emptyMessage;
  final FeedRowAction rowAction;
  final VoidCallback onChanged;

  const ArticleFeed({
    super.key,
    required this.articles,
    this.sourceTitles = const {},
    required this.emptyMessage,
    this.rowAction = FeedRowAction.readLater,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (articles.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(emptyMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16)),
        ),
      );
    }

    // Ordered ids of the whole (filtered) feed, so the article screen can swipe
    // to the next/previous one.
    final articleIds = [for (final a in articles) a.id!];

    // Interleave day headers with the articles of that day.
    final entries = <Object>[];
    DateTime? currentDay;
    for (final article in articles) {
      final date = DateTime.fromMillisecondsSinceEpoch(
          article.publishedAt ?? article.createdAt);
      final day = DateTime(date.year, date.month, date.day);
      if (day != currentDay) {
        entries.add(day);
        currentDay = day;
      }
      entries.add(article);
    }

    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, index) {
        final isLastOfDay =
            index + 1 < entries.length && entries[index + 1] is DateTime;
        return entries[index] is Article && !isLastOfDay
            ? const Divider()
            : const SizedBox.shrink();
      },
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry is DateTime) return _DayHeader(day: entry);
        return _ArticleTile(
          article: entry as Article,
          sourceTitle: sourceTitles[(entry).sourceId],
          articleIds: articleIds,
          rowAction: rowAction,
          onChanged: onChanged,
        );
      },
    );
  }
}

class _DayHeader extends StatelessWidget {
  final DateTime day;
  const _DayHeader({required this.day});

  String get _label {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    final format = day.year == now.year
        ? DateFormat('EEEE, MMMM d')
        : DateFormat('EEEE, MMMM d, y');
    return format.format(day);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: Text(
        _label.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _ArticleTile extends StatelessWidget {
  final Article article;
  final String? sourceTitle;

  /// Ordered ids of the feed this tile belongs to, for swipe navigation.
  final List<int> articleIds;
  final FeedRowAction rowAction;
  final VoidCallback onChanged;

  const _ArticleTile({
    required this.article,
    this.sourceTitle,
    required this.articleIds,
    required this.rowAction,
    required this.onChanged,
  });

  Widget _actionButton() {
    switch (rowAction) {
      case FeedRowAction.readLater:
        final saved = article.readLater == 1;
        return IconButton(
          tooltip: saved ? 'Remove from To Read' : 'Read later',
          iconSize: 26,
          icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
          onPressed: () async {
            await AppDatabase.instance.setReadLater(article.id!, !saved);
            onChanged();
          },
        );
      case FeedRowAction.unfavorite:
        return IconButton(
          tooltip: 'Remove from Favorites',
          iconSize: 26,
          icon: const Icon(Icons.star),
          onPressed: () async {
            await AppDatabase.instance.setFavorite(article.id!, false);
            onChanged();
          },
        );
    }
  }

  /// Status shown for an article whose content isn't on the device yet:
  /// "downloading…" while its fetch is in flight, "not downloaded" when the
  /// device looks offline, otherwise "queued for download" (the next sync —
  /// or the one running — will pick it up).
  String? get _downloadStatus {
    if (article.fetched != 0) return null;
    final sync = SyncService.instance;
    if (sync.downloadingArticleId == article.id) return 'downloading…';
    if (sync.lastKnownOffline) return 'not downloaded';
    return 'queued for download';
  }

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (sourceTitle != null) sourceTitle!,
      if (article.author != null && article.author!.isNotEmpty)
        article.author!,
      if (_downloadStatus != null) _downloadStatus!,
    ].join(' · ');

    final tile = ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4, top: 6,
          bottom: 6),
      title: Text(
        article.displayTitle,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 17,
          height: 1.3,
          fontWeight: article.read == 0 ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      subtitle: meta.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(meta, style: const TextStyle(fontSize: 13)),
            ),
      trailing: _actionButton(),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(
                  articleId: article.id!,
                  articleIds: articleIds,
                  initialIndex: articleIds.indexOf(article.id!),
                )));
        onChanged();
      },
    );

    // Every unread row that opens an article can be swiped right to mark it
    // read — one gesture, consistent across the whole app (same as the
    // Resume reading section and universal search). The row snaps back
    // restyled, never dismissed.
    return MarkReadSwipe(
      article: article,
      onChanged: onChanged,
      child: tile,
    );
  }
}

/// Wraps a row so that, while [article] is unread, swiping it right marks it
/// read — a single gesture that stays identical wherever an article row
/// appears (the feed and universal search). The row snaps back and re-renders
/// as read; it is never dismissed. A row for an already-read article is
/// returned unwrapped.
class MarkReadSwipe extends StatelessWidget {
  final Article article;

  /// Called after the article is marked read so the host list can refresh in
  /// place (the row restyles from bold to regular).
  final VoidCallback onChanged;
  final Widget child;

  const MarkReadSwipe({
    super.key,
    required this.article,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (article.read != 0) return child;
    return Dismissible(
      key: ValueKey('mark-read-${article.id}'),
      direction: DismissDirection.startToEnd,
      background: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerLeft,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, color: Colors.white),
            SizedBox(width: 8),
            Text('Mark as read',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        await AppDatabase.instance.markArticleRead(article.id!);
        onChanged();
        return false; // keep the row; it re-renders as read
      },
      child: child,
    );
  }
}
