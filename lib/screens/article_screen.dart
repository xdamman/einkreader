import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/archive_store.dart';
import '../services/share_actions.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/markdown_view.dart';
import 'share_screen.dart';

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

  /// The article this one was saved from (via a tapped link), for the
  /// "From: …" line in the header. Null for regular articles.
  Article? _viaArticle;

  /// The article's source, for the origin prefix in the top bar.
  Source? _source;
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
    final via = article?.viaArticleId == null
        ? null
        : await _db.getArticle(article!.viaArticleId!);
    final source =
        article == null ? null : await _db.getSource(article.sourceId);
    if (!mounted) return;
    setState(() {
      _article = article;
      _viaArticle = via;
      _source = source;
      _highlights = highlights;
    });
    // One-time per article (not on highlight/reprocess reloads, which also
    // land here): restore the saved position or auto-read a short article.
    if (article != null && _preparedId != article.id) {
      _preparedId = article.id;
      _reachedBottom = false;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _prepareScroll(article));
    }
  }

  /// Swipe left → next article in the feed (no-op past the end).
  void _goToNext() {
    if (_index >= _ids.length - 1) return;
    _saveProgress();
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
    _saveProgress();
    setState(() => _index--);
    _load();
  }

  // ------------------------------------------------------- reading progress
  // An unread article becomes "reading" (position saved, shown under Resume
  // reading) once the user scrolls down; scrolling back to the top before
  // ever reaching the bottom resets it to unread, and reaching the bottom
  // marks it read. Read articles are left alone — only an explicit
  // "mark as unread" restarts the cycle.

  final ScrollController _scroll = ScrollController();

  /// Whether the bottom was reached for the article currently on screen.
  bool _reachedBottom = false;

  /// Article id whose post-layout preparation (restore / auto-read) ran, so
  /// reloads after highlighting or reprocessing don't yank the scroll back.
  int? _preparedId;

  /// Scrolls shorter than this (px) don't count as "started reading".
  static const double _minReadingOffset = 24;

  /// After the article's first layout: jump to the saved reading position, or
  /// mark an article that fits entirely on screen as read — its bottom is
  /// visible on open and no scrolling can ever happen.
  void _prepareScroll(Article article) {
    if (!mounted || !_scroll.hasClients || _currentId != article.id) return;
    final maxExtent = _scroll.position.maxScrollExtent;
    if (maxExtent <= 0) {
      _reachedBottom = true;
      if (article.read == 0) _markRead();
      return;
    }
    if (article.read == 0 && article.scrollPosition > 0) {
      _scroll.jumpTo(article.scrollPosition.clamp(0.0, maxExtent));
    }
  }

  void _onScroll(ScrollMetrics metrics, {required bool settled}) {
    final article = _article;
    if (article == null || metrics.axis != Axis.vertical) return;
    if (!_reachedBottom &&
        metrics.maxScrollExtent > 0 &&
        metrics.pixels >= metrics.maxScrollExtent - 8) {
      _reachedBottom = true;
      if (article.read == 0) _markRead();
      return;
    }
    // Persist on scroll end only: e-ink scrolling is discrete, so this stays
    // cheap. Back near the top saves 0, which resets the article to unread.
    if (settled && !_reachedBottom && article.read == 0) {
      final offset = metrics.pixels;
      _db.saveScrollPosition(
          article.id!, offset < _minReadingOffset ? 0 : offset);
    }
  }

  /// Saves the current position when leaving the article (swipe or pop).
  void _saveProgress() {
    final article = _article;
    if (article == null || article.read != 0 || _reachedBottom) return;
    if (!_scroll.hasClients) return;
    final offset = _scroll.position.pixels;
    _db.saveScrollPosition(
        article.id!, offset < _minReadingOffset ? 0 : offset);
  }

  Future<void> _markRead() async {
    final article = _article;
    if (article == null || article.read != 0) return;
    await _db.markArticleRead(article.id!);
    final updated = await _db.getArticle(article.id!);
    if (!mounted || updated == null || updated.id != _currentId) return;
    setState(() => _article = updated);
  }

  @override
  void dispose() {
    _saveProgress();
    _scroll.dispose();
    super.dispose();
  }

  // Swipe detection via raw pointer events (a Listener), not a GestureDetector:
  // the reader's SelectionArea claims horizontal drags in the gesture arena, so
  // a competing recognizer never fires. A Listener observes pointers passively
  // without disturbing selection or scrolling.
  Offset? _dragStart;
  Duration? _dragStartTime;
  int _activePointers = 0;

  void _onPointerDown(PointerDownEvent event) {
    _activePointers++;
    if (_activePointers > 1) {
      // Multi-touch (e.g. the AINOTE's two-finger screen-refresh tap) is never
      // a swipe. Without this guard the second finger's down overwrites the
      // first finger's start, and the up→down delta spans two different
      // fingers — which reads as a huge, near-instant "fling".
      _dragStart = null;
      _dragStartTime = null;
      return;
    }
    _dragStart = event.position;
    _dragStartTime = event.timeStamp;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointers > 0) _activePointers--;
    _dragStart = null;
    _dragStartTime = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_activePointers > 0) _activePointers--;
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

  /// A tapped link offers to open in the browser (online) and/or save the
  /// page to read later. Saving queues it for download (immediately when
  /// online, on the next sync otherwise), bookmarks it under To Read, and
  /// remembers this article as where it came from.
  Future<void> _onLinkTap(String url, String anchorText) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    final online = await SyncService.instance.isOnline();
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                online ? url : 'You\'re offline\n$url',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const Divider(height: 1),
            if (online)
              ListTile(
                leading: const Icon(Icons.open_in_browser),
                title: const Text('Open in browser'),
                onTap: () => Navigator.pop(context, 'open'),
              ),
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('Read later'),
              subtitle: Text(online
                  ? 'Download now and add to To Read'
                  : 'Added to To Read; downloads when back online'),
              onTap: () => Navigator.pop(context, 'save'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'open') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    final saved = await _db.saveLinkForLater(
      url: url,
      title: anchorText,
      viaArticleId: _currentId,
    );
    if (online && saved.fetched == 0) {
      unawaited(SyncService.instance.downloadArticle(saved.id!));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(online
            ? 'Saved to To Read — downloading'
            : 'Saved to To Read — will download when back online')));
  }

  // ------------------------------------------------------------------ share

  /// The top-bar share menu: open in the browser, share the article or its
  /// highlights by email, or — when a Twitter account is connected — post
  /// either as a tweet (edited in a dialog first).
  Future<void> _showShareMenu() async {
    final article = _article;
    if (article == null) return;
    final twitterConnected = await ShareActions.twitterConnected();
    if (!mounted) return;
    final highlightCount = Text('${_highlights.length} '
        'highlight${_highlights.length == 1 ? '' : 's'}');
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (article.url != null)
              ListTile(
                leading: const Icon(Icons.open_in_browser),
                title: const Text('Open in browser'),
                onTap: () => Navigator.pop(sheetContext, 'browser'),
              ),
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Share article by email'),
              onTap: () => Navigator.pop(sheetContext, 'email'),
            ),
            if (_highlights.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.format_quote_outlined),
                title: const Text('Share highlights by email'),
                subtitle: highlightCount,
                onTap: () => Navigator.pop(sheetContext, 'highlights-email'),
              ),
            if (twitterConnected) ...[
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('Share on Twitter'),
                onTap: () => Navigator.pop(sheetContext, 'twitter'),
              ),
              if (_highlights.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.alternate_email),
                  title: const Text('Share highlights on Twitter'),
                  subtitle: highlightCount,
                  onTap: () =>
                      Navigator.pop(sheetContext, 'highlights-twitter'),
                ),
            ],
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'browser':
        await launchUrl(Uri.parse(article.url!),
            mode: LaunchMode.externalApplication);
      case 'email':
        await ShareActions.byEmail(
          context,
          subject: article.displayTitle,
          body: [
            article.displayTitle,
            if (article.author != null && article.author!.isNotEmpty)
              'by ${article.author}',
            if (article.url != null) article.url!,
          ].join('\n'),
        );
      case 'highlights-email':
        await ShareActions.byEmail(
          context,
          subject:
              ShareActions.highlightsSubject(article, _highlights.length),
          body: ShareActions.highlightsBody(article, _highlights),
        );
      case 'twitter':
        await ShareActions.tweetArticle(context, article);
      case 'highlights-twitter':
        await ShareActions.tweetHighlights(context, article, _highlights);
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

  /// The markdown the reader renders (mirrored in build).
  String get _renderedContent =>
      _article?.contentMarkdown ??
      _article?.summary ??
      '*This article has not been downloaded yet. '
          'Sync while online to read it offline.*';

  /// Saves the selection as a highlight immediately — no dialog, so marking
  /// several passages in a row stays fast. Notes, sharing and removal live
  /// in the small menu that opens when tapping the painted highlight.
  Future<void> _saveHighlight() async {
    var text = _selectedText.trim();
    final article = _article;
    if (text.isEmpty || article == null) return;
    // A selection spanning paragraphs arrives glued (SelectionArea drops the
    // newlines between blocks); restore them so the highlight paints and
    // shares correctly.
    text = MarkdownView.repairSelection(text, _renderedContent);
    await _db.insertHighlight(Highlight(
      articleId: article.id!,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final highlights = await _db.getHighlights(articleId: _currentId);
    if (!mounted) return;
    setState(() => _highlights = highlights);
    // A highlighted article is worth keeping: copy it to favorites and refresh
    // the time-independent highlights file.
    await _archiveFavorite(article);
    await _rewriteHighlights();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Highlighted')));
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

  /// Tapping a painted highlight opens a small menu anchored at the tap
  /// point — not a bottom sheet: on e-ink, repainting a few menu rows next
  /// to the finger beats redrawing a whole drawer. It carries everything:
  /// note, sharing, removal.
  Future<void> _manageHighlight(String text, Offset position) async {
    Highlight? match;
    for (final h in _highlights) {
      if (h.text == text) {
        match = h;
        break;
      }
    }
    if (match == null) return;
    final highlight = match;
    if (!mounted) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasNote = (highlight.comment ?? '').isNotEmpty;
    final action = await showMenu<String>(
      context: context,
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      position: RelativeRect.fromRect(
        Rect.fromCenter(center: position, width: 1, height: 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
            value: 'note',
            child: Text(hasNote ? 'Edit note' : 'Add note')),
        const PopupMenuItem(value: 'share', child: Text('Share…')),
        const PopupMenuDivider(),
        const PopupMenuItem(
            value: 'remove', child: Text('Remove highlight')),
      ],
    );
    if (!mounted || action == null) return;
    final article = _article;
    if (action == 'note') {
      await _editNote(highlight);
    } else if (action == 'share' && article != null) {
      // The full composer: comment + every destination in one place.
      await ShareScreen.open(context,
          article: article, highlight: highlight);
      final highlights = await _db.getHighlights(articleId: _currentId);
      if (!mounted) return;
      setState(() => _highlights = highlights);
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

  /// Small dialog to attach (or edit) a private note on a highlight.
  Future<void> _editNote(Highlight highlight) async {
    final controller = TextEditingController(text: highlight.comment ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Your private note on this passage'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (note == null || !mounted) return;
    await _db.updateHighlightComment(highlight.id!, note);
    final highlights = await _db.getHighlights(articleId: _currentId);
    if (!mounted) return;
    setState(() => _highlights = highlights);
  }

  /// Origin shown before the title in the top bar: the feed's name, or — for
  /// saved links, which all live under the generic Saved Links source — the
  /// domain the article was published on (e.g. "BX1: …" / "brusselstimes.com:
  /// …").
  String? get _originLabel {
    final article = _article;
    if (article == null) return null;
    final source = _source;
    if (source != null && source.type != SourceType.savedLinks) {
      return source.title;
    }
    final host = Uri.tryParse(article.url ?? '')?.host ?? '';
    if (host.isNotEmpty) return host.replaceFirst(RegExp(r'^www\.'), '');
    return source?.title;
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

    final content = _renderedContent;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            _originLabel == null
                ? article.displayTitle
                : '$_originLabel: ${article.displayTitle}',
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
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: _showShareMenu,
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
        onPointerCancel: _onPointerCancel,
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
        child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification ||
              notification is ScrollEndNotification) {
            _onScroll(notification.metrics,
                settled: notification is ScrollEndNotification);
          }
          return false;
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
              controller: _scroll,
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
                  // Saved links remember the story they were found in.
                  if (_viaArticle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => ArticleScreen(
                                    articleId: _viaArticle!.id!))),
                        child: Text(
                          'From: ${_viaArticle!.displayTitle}',
                          style: TextStyle(
                            fontSize: _fontSize - 4,
                            fontStyle: FontStyle.italic,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
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
                    onLinkTap: _onLinkTap,
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
      ),
    );
  }
}
