import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../widgets/article_feed.dart';

/// Articles of a single source, date-grouped like the main feed.
class ArticleListScreen extends StatefulWidget {
  final Source source;

  const ArticleListScreen({super.key, required this.source});

  @override
  State<ArticleListScreen> createState() => _ArticleListScreenState();
}

class _ArticleListScreenState extends State<ArticleListScreen> {
  final _db = AppDatabase.instance;
  List<Article> _articles = [];
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final articles = await _db.getArticles(sourceId: widget.source.id);
    if (!mounted) return;
    setState(() => _articles = articles);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _unreadOnly
        ? _articles.where((a) => a.read == 0).toList()
        : _articles;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source.title, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => setState(() => _unreadOnly = !_unreadOnly),
            child: Text(_unreadOnly ? 'Unread' : 'All',
                style: const TextStyle(
                    fontSize: 15, decoration: TextDecoration.underline)),
          ),
        ],
      ),
      body: ArticleFeed(
        articles: shown,
        emptyMessage:
            _unreadOnly ? 'No unread articles' : 'No articles yet',
        onChanged: _load,
      ),
    );
  }
}
