import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/archive_store.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/markdown_view.dart';

/// Reader screen. Select any text and choose "Highlight" from the selection
/// menu to save it; saved highlights are painted inline with a grey wash and
/// can be tapped to share or remove them.
class ArticleScreen extends StatefulWidget {
  final int articleId;

  /// The active feed's article ids in display order, enabling swipe navigation
  /// between them. Null (e.g. opened from Highlights) means a single article.
  final List<int>? articleIds;

  /// Position of [articleId] within [articleIds]; swiping left from here pops
  /// back to the feed rather than to an earlier article.
  final int? initialIndex;

  /// Optional highlight to reveal context for (from the Highlights screen).
  final String? focusHighlight;

  const ArticleScreen({super.key, required this.articleId,
      this.articleIds, this.initialIndex, this.focusHighlight});

  @override
  State<ArticleScreen> createState() => _ArticleScreenState();
}

class _ArticleScreenState extends State<ArticleScreen> {
  final _db = AppDatabase.instance;
  Article? _article;
  List<Highlight> _highlights = [];
  String _selectedText = '';
  double _fontSize = 18;
  bool _reprocessing = false;

  /// Ordered feed ids and where we are in them. [_startIndex] is the article
  /// the user opened; swiping left from it returns to the feed.
  late final List<int> _ids;
  late final int _startIndex;
  late int _index;

  int get _currentId => _ids[_index];

  @override
  void initState() {
    super.initState();
    _ids = widget.articleIds ?? [widget.articleId];
    final at = widget.initialIndex ?? _ids.indexOf(widget.articleId);
    _startIndex = (at < 0 || at >= _ids.length) ? 0 : at;
    _index = _startIndex;
    _load();
  }

  Future<void> _load() async {
    final article = await _db.getArticle(_currentId);
    final highlights = await _db.getHighlights(articleId: _currentId);
    if (!mounted) return;
    setState(() {
      _article = article;
      _highlights = highlights;
    });
    if (article != null && article.read == 0) {
      await _db.markArticleRead(article.id!);
    }
  }

  /// Swipe left → next article in the feed (no-op past the end).
  void _goToNext() {
    if (_index >= _ids.length - 1) return;
    setState(() => _index++);
    _load();
  }

  /// Swipe right → previous article, or back to the feed when we're at the
  /// article that was first opened.
  void _goToPreviousOrBack() {
    if (_index <= _startIndex) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index--);
    _load();
  }

  // Swipe detection via raw pointer events (a Listener), not a GestureDetector:
  // the reader's SelectionArea claims horizontal drags in the gesture arena, so
  // a competing recognizer never fires. A Listener observes pointers passively
  // without disturbing selection or scrolling.
  Offset? _dragStart;
  Duration? _dragStartTime;

  void _onPointerDown(PointerDownEvent event) {
    _dragStart = event.position;
    _dragStartTime = event.timeStamp;
  }

  void _onPointerUp(PointerUpEvent event) {
    final start = _dragStart;
    final startTime = _dragStartTime;
    _dragStart = null;
    _dragStartTime = null;
    if (start == null || startTime == null) return;

    final dx = event.position.dx - start.dx;
    final dy = event.position.dy - start.dy;
    final ms = (event.timeStamp - startTime).inMilliseconds;
    final speed = ms > 0 ? dx.abs() / ms * 1000 : double.infinity; // px/s

    // A deliberate horizontal fling: far enough, clearly horizontal, and quick
    // enough to not be a scroll or a slow text-selection drag.
    if (dx.abs() < 60 || dx.abs() < dy.abs() * 1.5 || speed < 300) return;
    // Book convention: swiping left pulls in the next article, swiping right
    // turns back (to the previous article, then out to the feed).
    if (dx < 0) {
      _goToNext(); // swipe left
    } else {
      _goToPreviousOrBack(); // swipe right
    }
  }

  Future<void> _toggleFavorite() async {
    final article = _article;
    if (article == null) return;
    final favorite = article.favorite == 0;
    await _db.setFavorite(article.id!, favorite);
    final updated = await _db.getArticle(article.id!);
    if (!mounted) return;
    setState(() => _article = updated);
    if (favorite && updated != null) await _archiveFavorite(updated);
  }

  Future<void> _saveHighlight() async {
    final text = _selectedText.trim();
    if (text.isEmpty || _article == null) return;
    await _db.insertHighlight(Highlight(
      articleId: _article!.id!,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final highlights = await _db.getHighlights(articleId: _currentId);
    if (!mounted) return;
    setState(() => _highlights = highlights);
    // A highlighted article is worth keeping: copy it to favorites and refresh
    // the time-independent highlights file.
    await _archiveFavorite(_article!);
    await _rewriteHighlights();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Highlight saved')));
  }

  /// Re-downloads and re-processes the article, then re-renders it.
  Future<void> _reprocess() async {
    if (_reprocessing) return;
    setState(() => _reprocessing = true);
    String message = 'Article reprocessed';
    try {
      await SyncService.instance.reprocessArticle(_currentId);
    } catch (e) {
      message = 'Couldn\'t reprocess: $e';
    }
    // Drop cached images so re-downloaded versions show.
    PaintingBinding.instance.imageCache.clear();
    if (!mounted) return;
    setState(() => _reprocessing = false);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Copies an article's markdown + images into YYYY/MM/favorites/ so it
  /// survives even if its source is later removed.
  Future<void> _archiveFavorite(Article article) async {
    final markdown = article.contentMarkdown;
    if (markdown == null) return;
    final source = await _db.getSource(article.sourceId);
    if (source == null) return;
    await ArchiveStore.instance
        .copyToFavorites(source: source, article: article, markdown: markdown);
  }

  Future<void> _rewriteHighlights() async {
    await ArchiveStore.instance.writeHighlights(await _db.getHighlights());
  }

  /// Tapping a painted highlight offers to share or remove it.
  Future<void> _manageHighlight(String text) async {
    Highlight? match;
    for (final h in _highlights) {
      if (h.text == text) {
        match = h;
        break;
      }
    }
    if (match == null) return;
    final highlight = match;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                highlight.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontStyle: FontStyle.italic),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove highlight'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'share') {
      final title = _article?.title;
      final shareText = title == null ? highlight.text
          : '"${highlight.text}"\n\n— $title';
      await Share.share(shareText);
    } else if (action == 'remove') {
      await _db.deleteHighlight(highlight.id!);
      final highlights = await _db.getHighlights(articleId: _currentId);
      await _rewriteHighlights();
      if (!mounted) return;
      setState(() => _highlights = highlights);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Highlight removed')));
    }
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
          IconButton(
            tooltip: 'Reload & reprocess',
            icon: _reprocessing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _reprocessing ? null : _reprocess,
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
      body: Listener(
        key: const Key('articleSwipe'),
        // Swipe left → next article, swipe right → previous (or back to the
        // feed at the first-opened one). See _onPointerUp for why this is a
        // Listener rather than a GestureDetector.
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: SelectionArea(
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
              // New identity per article so scroll resets to the top on swipe.
              key: ValueKey(_currentId),
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
                    onHighlightTap: _manageHighlight,
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
      ),
    );
  }
}
