import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../screens/article_screen.dart';

/// The Shared column: everything that left the device — per highlight, with
/// destination chips — filterable by medium and recipient (the same chip
/// strip pattern as the feed's source strip).
class SharedList extends StatefulWidget {
  final List<Share> shares;
  final VoidCallback onChanged;

  const SharedList(
      {super.key, required this.shares, required this.onChanged});

  @override
  State<SharedList> createState() => _SharedListState();
}

class _SharedListState extends State<SharedList> {
  /// null = All; 'medium:profile' | 'medium:twitter' | … | 'to:Marc'.
  String? _filter;

  static String _mediumLabel(String medium) => switch (medium) {
        'profile' => '⌂ profile',
        'twitter' => '@ tweeted',
        'email' => '✉ email',
        'link' => '🔗 link',
        _ => medium,
      };

  @override
  Widget build(BuildContext context) {
    if (widget.shares.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Nothing shared yet.\n\nTap any highlight while reading and '
            'choose "Share…" — what you send out shows up here, with where '
            'it went.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      );
    }

    final mediums =
        widget.shares.map((s) => s.medium).toSet().toList()..sort();
    final recipients = widget.shares
        .map((s) => s.recipient)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();

    final visible = widget.shares.where((s) {
      final filter = _filter;
      if (filter == null) return true;
      if (filter.startsWith('medium:')) {
        return s.medium == filter.substring(7);
      }
      return s.recipient == filter.substring(3);
    }).toList();

    // Group by highlight, newest share first (list is already sorted).
    final groups = <int, List<Share>>{};
    for (final share in visible) {
      groups.putIfAbsent(share.highlightId, () => []).add(share);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 1)),
          ),
          child: SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                _chip('All', _filter == null, () => _select(null)),
                for (final medium in mediums)
                  _chip(_mediumLabel(medium), _filter == 'medium:$medium',
                      () => _select('medium:$medium')),
                for (final recipient in recipients)
                  _chip(recipient, _filter == 'to:$recipient',
                      () => _select('to:$recipient')),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final entry in groups.entries)
                _highlightTile(context, entry.value),
            ],
          ),
        ),
      ],
    );
  }

  void _select(String? filter) => setState(() => _filter = filter);

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.black : Colors.white,
            border: Border.all(width: 1.5),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : Colors.black)),
        ),
      ),
    );
  }

  Widget _highlightTile(BuildContext context, List<Share> shares) {
    final first = shares.first;
    final date = DateFormat.yMMMd()
        .format(DateTime.fromMillisecondsSinceEpoch(first.createdAt));
    return InkWell(
      onTap: () async {
        final articleId = first.articleId;
        if (articleId == null) return;
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ArticleScreen(
                articleId: articleId,
                focusHighlight: first.highlightText)));
        widget.onChanged();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(width: 0.5)),
        ),
        child: Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(first.highlightText ?? '',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, height: 1.4)),
              if ((first.highlightComment ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(first.highlightComment!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontStyle: FontStyle.italic)),
                ),
              const SizedBox(height: 4),
              Text('${first.articleTitle ?? ''} · $date',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  for (final share in shares)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(width: 1.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                          share.recipient != null
                              ? '✉ ${share.recipient}'
                              : _mediumLabel(share.medium),
                          style: const TextStyle(fontSize: 11)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
