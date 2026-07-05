import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../screens/article_screen.dart';

/// "Resume reading" section shown at the top of the Feed tab: articles the
/// user started but hasn't finished (unread, with a saved scroll position,
/// not parked in To Read), most recently touched first.
///
/// Each row can be swiped right to mark as read, swiped left to mark as
/// unread (dropping the saved position), or bookmarked via the trailing
/// button to move it to the To Read tab.
class ResumeReadingSection extends StatelessWidget {
  final List<Article> articles;

  /// Source id → source title, shown in each row's meta line.
  final Map<int, String> sourceTitles;
  final VoidCallback onChanged;

  /// Rows shown at most, so a long backlog can't crowd out the feed below.
  static const int maxRows = 5;

  const ResumeReadingSection({
    super.key,
    required this.articles,
    this.sourceTitles = const {},
    required this.onChanged,
  });

  /// The current reads out of [articles], in Resume reading order.
  static List<Article> currentReads(List<Article> articles) =>
      articles
          .where((a) =>
              a.read == 0 && a.readLater == 0 && a.scrollPosition > 0)
          .toList()
        ..sort((a, b) => (b.scrolledAt ?? 0).compareTo(a.scrolledAt ?? 0));

  @override
  Widget build(BuildContext context) {
    final shown = articles.take(maxRows).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final ids = [for (final a in shown) a.id!];
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(width: 1)),
            ),
            child: Text(
              articles.length > shown.length
                  ? 'RESUME READING · ${shown.length} OF ${articles.length}'
                  : 'RESUME READING',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _ResumeTile(
              article: shown[i],
              sourceTitle: sourceTitles[shown[i].sourceId],
              articleIds: ids,
              index: i,
              onChanged: onChanged,
            ),
          ],
        ],
      ),
    );
  }
}

class _ResumeTile extends StatelessWidget {
  final Article article;
  final String? sourceTitle;
  final List<int> articleIds;
  final int index;
  final VoidCallback onChanged;

  const _ResumeTile({
    required this.article,
    this.sourceTitle,
    required this.articleIds,
    required this.index,
    required this.onChanged,
  });

  /// Solid swipe-action backdrop, e-ink style: black with white icon + label.
  Widget _swipeBackground(IconData icon, String label,
      {required bool alignLeft}) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (sourceTitle != null) sourceTitle!,
      if (article.author != null && article.author!.isNotEmpty)
        article.author!,
    ].join(' · ');

    return Dismissible(
      key: ValueKey('resume-${article.id}'),
      background: _swipeBackground(Icons.check, 'Mark as read',
          alignLeft: true),
      secondaryBackground: _swipeBackground(
          Icons.mark_email_unread_outlined, 'Mark as unread',
          alignLeft: false),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await AppDatabase.instance.markArticleRead(article.id!);
        } else {
          // Unread: keep read = 0, just drop the saved position.
          await AppDatabase.instance.saveScrollPosition(article.id!, 0);
        }
        return true;
      },
      onDismissed: (_) => onChanged(),
      child: ListTile(
        contentPadding:
            const EdgeInsets.only(left: 16, right: 4, top: 2, bottom: 2),
        leading: const Icon(Icons.menu_book_outlined, size: 26),
        title: Text(
          article.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            height: 1.3,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: meta.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(meta, style: const TextStyle(fontSize: 13)),
              ),
        trailing: IconButton(
          tooltip: 'Read later',
          iconSize: 26,
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: () async {
            await AppDatabase.instance.setReadLater(article.id!, true);
            onChanged();
          },
        ),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ArticleScreen(
                    articleId: article.id!,
                    articleIds: articleIds,
                    initialIndex: index,
                  )));
          onChanged();
        },
      ),
    );
  }
}
