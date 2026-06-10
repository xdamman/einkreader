import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../models.dart';
import 'article_screen.dart';

class ArticleListScreen extends StatefulWidget {
  /// When null, shows articles from all sources.
  final Source? source;

  const ArticleListScreen({super.key, this.source});

  @override
  State<ArticleListScreen> createState() => _ArticleListScreenState();
}

class _ArticleListScreenState extends State<ArticleListScreen> {
  final _db = AppDatabase.instance;
  List<Article> _articles = [];
  bool _unreadOnly = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final articles = await _db.getArticles(sourceId: widget.source?.id);
    if (!mounted) return;
    setState(() {
      _articles = articles;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _unreadOnly
        ? _articles.where((a) => a.read == 0).toList()
        : _articles;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source?.title ?? 'All articles',
            overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
            child: Text(_unreadOnly ? 'Unread' : 'All',
                style: const TextStyle(
                    fontSize: 15, decoration: TextDecoration.underline)),
          ),
        ],
      ),
      body: _loading
          ? const SizedBox.shrink()
          : shown.isEmpty
              ? Center(
                  child: Text(
                      _unreadOnly ? 'No unread articles' : 'No articles yet',
                      style: const TextStyle(fontSize: 16)),
                )
              : ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) =>
                      _articleTile(shown[index]),
                ),
    );
  }

  Widget _articleTile(Article article) {
    final date = article.publishedAt != null
        ? DateFormat.yMMMd()
            .format(DateTime.fromMillisecondsSinceEpoch(article.publishedAt!))
        : null;
    final meta = [
      if (article.author != null && article.author!.isNotEmpty)
        article.author!,
      if (date != null) date,
      if (article.fetched == 0) 'not downloaded',
    ].join(' · ');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      title: Text(
        article.title,
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
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(articleId: article.id!)));
        _load();
      },
    );
  }
}
