import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../widgets/article_feed.dart';
import 'article_screen.dart';

/// Status filter chips on the search screen. Each narrows the article list;
/// [highlighted] additionally keeps only articles the reader has highlighted.
enum _StatusFilter {
  all('All'),
  unread('Unread'),
  read('Read'),
  favorites('★ Favorites'),
  highlighted('Highlighted');

  final String label;
  const _StatusFilter(this.label);
}

/// Full-screen universal search over everything the reader stores — sources,
/// authors, article titles and content, and highlights (with their comments).
/// Highlights always rank first. Two chip rows narrow the article results by
/// status and by source; highlights stay visible except under Unread/Read,
/// where they follow their article's state. No modals — one clean e-ink
/// repaint, back to leave.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _db = AppDatabase.instance;
  final _controller = TextEditingController();
  Timer? _debounce;

  String _query = '';
  SearchResults? _results;
  Map<int, String> _sourceTitles = {};

  _StatusFilter _status = _StatusFilter.all;

  /// Source chip selection (a source id), or null for all sources.
  int? _sourceId;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final sources = await _db.getSources();
    if (!mounted) return;
    setState(() {
      _sourceTitles = {for (final s in sources) s.id!: s.title};
    });
  }

  /// Debounced so typing doesn't hammer the database; a query under two
  /// characters clears the results and shows the intro message.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final query = value.trim();
      if (query.length < 2) {
        setState(() {
          _query = query;
          _results = null;
        });
        return;
      }
      _run(query);
    });
  }

  Future<void> _run(String query) async {
    final results = await _db.search(query);
    if (!mounted) return;
    setState(() {
      _query = query;
      _results = results;
    });
  }

  /// Re-runs the current query in place (after marking a row read) so the
  /// results reflect the new state without losing the reader's position.
  Future<void> _refresh() async {
    if (_query.length >= 2) await _run(_query);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search everything…',
            border: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
          style: const TextStyle(fontSize: 18),
          onChanged: _onChanged,
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final results = _results;
    if (_query.length < 2 || results == null) {
      return const _CenteredMessage(
        'Search your whole library: sources, authors, titles, '
        'content and highlights.',
      );
    }
    if (results.isEmpty) {
      return _CenteredMessage('Nothing found for "$_query".');
    }

    // Faceted filtering: each chip row's counts are computed with the OTHER
    // row's filter applied, so the rows always describe what a tap would
    // actually show.
    final highlightedArticleIds = {
      for (final h in results.highlights) h.articleId
    };
    bool matchesStatus(Article a, _StatusFilter status) => switch (status) {
          _StatusFilter.all => true,
          _StatusFilter.unread => a.read == 0,
          _StatusFilter.read => a.read == 1,
          _StatusFilter.favorites => a.favorite == 1,
          _StatusFilter.highlighted => highlightedArticleIds.contains(a.id),
        };

    // Validate the selected source against matches under ANY status, so a
    // status change can hide but not silently forget the selection.
    final anyStatusSources = {
      for (final a in results.articles) a.sourceId
    };
    final sourceValid =
        anyStatusSources.contains(_sourceId) ? _sourceId : null;

    // Status counts respect the source selection; zero-count statuses are
    // not shown. A selected status that drops to zero falls back to All.
    final sourceFiltered = sourceValid == null
        ? results.articles
        : results.articles
            .where((a) => a.sourceId == sourceValid)
            .toList();
    final statusCounts = {
      for (final status in _StatusFilter.values)
        status: sourceFiltered.where((a) => matchesStatus(a, status)).length,
    };
    final effectiveStatus =
        statusCounts[_status]! > 0 ? _status : _StatusFilter.all;

    // Source counts respect the status selection: only sources that still
    // make sense under it, alphabetical (stable lists are alphabetical,
    // never by count), each with its count.
    final statusFiltered = results.articles
        .where((a) => matchesStatus(a, effectiveStatus))
        .toList();
    final matchesBySource = <int, int>{};
    for (final article in statusFiltered) {
      matchesBySource[article.sourceId] =
          (matchesBySource[article.sourceId] ?? 0) + 1;
    }
    final selectedSourceId =
        matchesBySource.containsKey(sourceValid) ? sourceValid : null;
    final sourceChips = matchesBySource.keys
        .map((id) => (
              id: id,
              title: _sourceTitles[id] ?? 'Unknown',
              count: matchesBySource[id]!,
            ))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final articles = selectedSourceId == null
        ? statusFiltered
        : statusFiltered
            .where((a) => a.sourceId == selectedSourceId)
            .toList();

    // Highlights stay visible except under Unread/Read, where they follow
    // their article's read state (mapped from the matching articles).
    final readById = {for (final a in results.articles) a.id: a.read};
    var highlights = results.highlights;
    if (effectiveStatus == _StatusFilter.unread ||
        effectiveStatus == _StatusFilter.read) {
      final wantRead = effectiveStatus == _StatusFilter.read ? 1 : 0;
      highlights = highlights
          .where((h) => readById[h.articleId] == wantRead)
          .toList();
    }

    final terms = _query.toLowerCase().split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 1)),
          ),
          child: Column(
            children: [
              _chipRow([
                for (final status in _StatusFilter.values)
                  // "All" always shows; the rest only when they have results.
                  if (status == _StatusFilter.all ||
                      statusCounts[status]! > 0)
                    _FilterChip(
                      label: status == _StatusFilter.all
                          ? status.label
                          : '${status.label} ${statusCounts[status]}',
                      selected: effectiveStatus == status,
                      onTap: () => setState(() => _status = status),
                    ),
              ]),
              // Only worth a source row when more than one source matched.
              if (sourceChips.length > 1) ...[
                const Divider(height: 1),
                _chipRow([
                  _FilterChip(
                    label: 'All',
                    selected: selectedSourceId == null,
                    onTap: () => setState(() => _sourceId = null),
                  ),
                  for (final chip in sourceChips)
                    _FilterChip(
                      label: '${chip.title} ${chip.count}',
                      selected: selectedSourceId == chip.id,
                      onTap: () => setState(() => _sourceId = chip.id),
                    ),
                ]),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              // Highlights always render above everything else.
              if (highlights.isNotEmpty) ...[
                const _SectionHeader('Highlights'),
                for (final highlight in highlights)
                  _HighlightResult(highlight: highlight, onChanged: _refresh),
              ],
              if (articles.isNotEmpty) ...[
                const _SectionHeader('Articles'),
                for (final article in articles)
                  _ArticleResult(
                    article: article,
                    sourceTitle: _sourceTitles[article.sourceId],
                    terms: terms,
                    onChanged: _refresh,
                  ),
              ],
              if (results.sources.isNotEmpty) ...[
                const _SectionHeader('Sources'),
                for (final source in results.sources)
                  _SourceResult(
                    source: source,
                    onTap: () => setState(() => _sourceId = source.id),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _chipRow(List<Widget> chips) => SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              chips[i],
            ],
          ],
        ),
      );
}

/// Centered instructional / empty-state message.
class _CenteredMessage extends StatelessWidget {
  final String message;
  const _CenteredMessage(this.message);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

/// Uppercase divider labelling a results group.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(width: 1)),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Flat, e-ink friendly pill: solid black when selected, outlined otherwise.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.black : Colors.white,
          border: Border.all(width: 1.5),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.black,
          ),
        ),
      ),
    );
  }
}

/// A matched highlight: the left-bar quote style shared with the Highlights
/// tab. Tapping opens the article with the highlight in view.
class _HighlightResult extends StatelessWidget {
  final Highlight highlight;
  final VoidCallback onChanged;

  const _HighlightResult({required this.highlight, required this.onChanged});

  @override
  Widget build(BuildContext context) {
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
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(
                articleId: highlight.articleId,
                focusHighlight: highlight.text)));
        onChanged();
      },
    );
  }
}

/// A matched article: bold title when unread, a "source · author" meta line
/// and — when the match is in the body — a one-line context snippet. Unread
/// rows swipe right to mark read, exactly like the feed.
class _ArticleResult extends StatelessWidget {
  final Article article;
  final String? sourceTitle;
  final List<String> terms;
  final VoidCallback onChanged;

  const _ArticleResult({
    required this.article,
    required this.sourceTitle,
    required this.terms,
    required this.onChanged,
  });

  /// ~80 characters of context around the first body match, or null when no
  /// term appears in the summary/content (the title already shows those hits).
  String? get _snippet {
    for (final raw in [article.summary, article.contentMarkdown]) {
      if (raw == null || raw.trim().isEmpty) continue;
      final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      final lower = flat.toLowerCase();
      int? at;
      for (final term in terms) {
        final i = lower.indexOf(term);
        if (i >= 0 && (at == null || i < at)) at = i;
      }
      if (at == null) continue;
      const pad = 40;
      final start = (at - pad).clamp(0, flat.length);
      final end = (at + pad).clamp(0, flat.length);
      final prefix = start > 0 ? '…' : '';
      final suffix = end < flat.length ? '…' : '';
      return '$prefix${flat.substring(start, end).trim()}$suffix';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (sourceTitle != null) sourceTitle!,
      if (article.author != null && article.author!.isNotEmpty)
        article.author!,
    ].join(' · ');
    final snippet = _snippet;

    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
      subtitle: (meta.isEmpty && snippet == null)
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (meta.isNotEmpty)
                    Text(meta, style: const TextStyle(fontSize: 13)),
                  if (snippet != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontStyle: FontStyle.italic),
                      ),
                    ),
                ],
              ),
            ),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(articleId: article.id!)));
        onChanged();
      },
    );

    return MarkReadSwipe(
      article: article,
      onChanged: onChanged,
      child: tile,
    );
  }
}

/// A matched source, shown as a compact row; tapping selects its chip.
class _SourceResult extends StatelessWidget {
  final Source source;
  final VoidCallback onTap;

  const _SourceResult({required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: const Icon(Icons.rss_feed, size: 20),
      title: Text(
        source.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        source.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      onTap: onTap,
    );
  }
}
