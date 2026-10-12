import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/suggested_sources.dart';
import '../services/sync_service.dart';

/// A first library to pick from: suggested feeds grouped by region, the
/// reader's own region first. A few are pre-selected; one tap adds them.
class SuggestedSourcesScreen extends StatefulWidget {
  /// The device locale unless a test sets one.
  final Locale? locale;

  const SuggestedSourcesScreen({super.key, this.locale});

  @override
  State<SuggestedSourcesScreen> createState() => _SuggestedSourcesScreenState();
}

class _SuggestedSourcesScreenState extends State<SuggestedSourcesScreen> {
  late final Locale _locale =
      widget.locale ?? WidgetsBinding.instance.platformDispatcher.locale;
  late final List<SuggestedRegion> _regions = regionsFor(_locale);
  late final Set<String> _selected = preselectedFor(_locale);
  bool _adding = false;

  Future<void> _add() async {
    setState(() => _adding = true);
    final db = AppDatabase.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    final added = <Source>[];
    final seen = <String>{};
    for (final region in _regions) {
      for (final feed in region.feeds) {
        if (!_selected.contains(feed.url) || !seen.add(feed.url)) continue;
        if (await db.getSourceByTypeAndUrl(SourceType.rss, feed.url) != null) {
          continue;
        }
        added.add(await db.insertSource(Source(
            type: SourceType.rss,
            title: feed.title,
            url: feed.url,
            createdAt: now)));
      }
    }
    unawaited(SyncService.instance.syncSources(added));
    if (mounted) Navigator.of(context).pop(added.length);
  }

  @override
  Widget build(BuildContext context) {
    final count = _selected.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Suggested reads')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          const Text(
            'Pick a few to start with. You can remove them, or add your own '
            'feeds, newsletters and bookmarks, any time.',
            style: TextStyle(fontSize: 15),
          ),
          for (final region in _regions) ...[
            Padding(
              padding: const EdgeInsets.only(top: 22, bottom: 4),
              child: Text(region.name.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1)),
            ),
            const Divider(height: 1, thickness: 1.5, color: Colors.black),
            for (final feed in region.feeds)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: Colors.black,
                checkColor: Colors.white,
                value: _selected.contains(feed.url),
                onChanged: _adding
                    ? null
                    : (on) => setState(() => on == true
                        ? _selected.add(feed.url)
                        : _selected.remove(feed.url)),
                title: Text(feed.title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                subtitle: Text(feed.description,
                    style: const TextStyle(fontSize: 13.5)),
              ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: count == 0 || _adding ? null : _add,
            child: Text(
              _adding
                  ? 'Adding…'
                  : count == 0
                      ? 'Pick at least one'
                      : 'Add $count source${count == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
