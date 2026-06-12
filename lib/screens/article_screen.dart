import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/markdown_view.dart';

/// Reader screen. Select any text and choose "Highlight" from the selection
/// menu to save it; saved highlights are painted inline with a grey wash.
class ArticleScreen extends StatefulWidget {
  final int articleId;

  /// Optional highlight to reveal context for (from the Highlights screen).
  final String? focusHighlight;

  const ArticleScreen({super.key, required this.articleId,
      this.focusHighlight});

  @override
  State<ArticleScreen> createState() => _ArticleScreenState();
}

class _ArticleScreenState extends State<ArticleScreen> {
  final _db = AppDatabase.instance;
  Article? _article;
  List<Highlight> _highlights = [];
  String _selectedText = '';
  double _fontSize = 18;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final article = await _db.getArticle(widget.articleId);
    final highlights = await _db.getHighlights(articleId: widget.articleId);
    if (!mounted) return;
    setState(() {
      _article = article;
      _highlights = highlights;
    });
    if (article != null && article.read == 0) {
      await _db.markArticleRead(article.id!);
    }
  }

  Future<void> _toggleFavorite() async {
    final article = _article;
    if (article == null) return;
    await _db.setFavorite(article.id!, article.favorite == 0);
    final updated = await _db.getArticle(article.id!);
    if (!mounted) return;
    setState(() => _article = updated);
  }

  Future<void> _saveHighlight() async {
    final text = _selectedText.trim();
    if (text.isEmpty || _article == null) return;
    await _db.insertHighlight(Highlight(
      articleId: _article!.id!,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final highlights = await _db.getHighlights(articleId: widget.articleId);
    if (!mounted) return;
    setState(() => _highlights = highlights);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Highlight saved')));
  }

  @override
  Widget build(BuildContext context) {
    final article = _article;
    if (article == null) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }

    final date = article.publishedAt != null
        ? DateFormat.yMMMMd()
            .format(DateTime.fromMillisecondsSinceEpoch(article.publishedAt!))
        : null;
    final meta = [
      if (article.author != null && article.author!.isNotEmpty)
        article.author!,
      if (date != null) date,
    ].join(' · ');

    final content = article.contentMarkdown ??
        article.summary ??
        '*This article has not been downloaded yet. '
            'Sync while online to read it offline.*';

    return Scaffold(
      appBar: AppBar(
        title: Text(article.title,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Smaller text',
            icon: const Icon(Icons.text_decrease),
            onPressed: () => setState(
                () => _fontSize = (_fontSize - 2).clamp(14, 30)),
          ),
          IconButton(
            tooltip: 'Larger text',
            icon: const Icon(Icons.text_increase),
            onPressed: () => setState(
                () => _fontSize = (_fontSize + 2).clamp(14, 30)),
          ),
          if (article.url != null)
            IconButton(
              tooltip: 'Open in browser',
              icon: const Icon(Icons.open_in_browser),
              onPressed: () => launchUrl(Uri.parse(article.url!),
                  mode: LaunchMode.externalApplication),
            ),
        ],
      ),
      body: SelectionArea(
        onSelectionChanged: (selection) =>
            _selectedText = selection?.plainText ?? '',
        contextMenuBuilder: (context, selectableRegionState) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: [
              ContextMenuButtonItem(
                label: 'Highlight',
                onPressed: () {
                  ContextMenuController.removeAny();
                  _saveHighlight();
                },
              ),
              ...selectableRegionState.contextMenuButtonItems,
            ],
          );
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Comfortable measure on tablets: cap the text column width.
            final horizontal = constraints.maxWidth > 720
                ? (constraints.maxWidth - 680) / 2
                : 20.0;
            return SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    article.title,
                    style: TextStyle(
                      fontSize: _fontSize + 10,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      fontFamily: readingFontFamily,
                      fontFamilyFallback: readingFontFallback,
                    ),
                  ),
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(meta,
                          style: TextStyle(
                              fontSize: _fontSize - 4,
                              fontStyle: FontStyle.italic)),
                    ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Divider(),
                  ),
                  MarkdownView(
                    markdown: content,
                    fontSize: _fontSize,
                    highlights: [for (final h in _highlights) h.text],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Divider(),
                  ),
                  Center(
                    child: OutlinedButton.icon(
                      icon: Icon(article.favorite == 1
                          ? Icons.star
                          : Icons.star_border),
                      label: Text(article.favorite == 1
                          ? 'Favorited'
                          : 'Add to favorites'),
                      onPressed: _toggleFavorite,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
