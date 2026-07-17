// highlights.md is a two-way document: the app writes it on every highlight
// change, and imports from it (additive, deduped by text) when its mtime
// says something else edited it. Covers:
//   - parseHighlights round-trips the writeHighlights format
//   - recovery: entries whose article was deleted come back, attached to a
//     placeholder that keeps the original title
//   - external edits are picked up; unchanged files cost nothing
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Directory tmp;
  late int keptArticleId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    tmp = Directory.systemTemp.createTempSync('einkreader_hl_import');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'archive'));

    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'kept',
      title: 'Kept Article',
      contentMarkdown: 'body',
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
    ));
    keptArticleId = (await db.getArticles()).single.id!;
  });

  test('parseHighlights round-trips the written format', () async {
    await db.insertHighlight(Highlight(
        articleId: keptArticleId, text: 'kept passage', createdAt: 1));
    await ArchiveStore.instance.writeHighlights([
      const Highlight(
          articleId: 1,
          text: 'kept passage',
          createdAt: 1,
          articleTitle: 'Kept Article'),
      const Highlight(
          articleId: 2,
          text: 'first line\nsecond line',
          createdAt: 2,
          articleTitle: 'Gone Tweet'),
    ]);
    final parsed = ArchiveStore.parseHighlights(
        await (await ArchiveStore.instance.highlightsFile()).readAsString());
    expect(parsed, [
      (title: 'Kept Article', text: 'kept passage'),
      (title: 'Gone Tweet', text: 'first line\nsecond line'),
    ]);
  });

  test('import recovers entries whose article is gone, exactly once',
      () async {
    // The file (written above) holds a highlight for "Gone Tweet", whose
    // article does not exist — the 20-vs-7 scenario. The app's own write
    // recorded the mtime, so first make the file look externally edited.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(ArchiveStore.highlightsSignaturePrefKey);

    expect(await db.getHighlights(), hasLength(1));
    final imported = await SyncService.instance.importHighlightsFromArchive();
    expect(imported, 1, reason: 'only the missing entry is imported');

    final highlights = await db.getHighlights();
    expect(highlights, hasLength(2));
    final recovered =
        highlights.firstWhere((h) => h.text == 'first line\nsecond line');
    expect(recovered.articleTitle, 'Gone Tweet',
        reason: 'placeholder keeps the original attribution');
    final placeholder = (await db.getArticle(recovered.articleId))!;
    final placeholderSource = (await db.getSource(placeholder.sourceId))!;
    expect(placeholderSource.type, SourceType.savedLinks);
    expect(placeholder.read, 1, reason: 'placeholders never count as unread');

    // Unchanged file: the next import is a no-op (mtime matches).
    expect(await SyncService.instance.importHighlightsFromArchive(), 0);
    // Even a forced re-run inserts nothing (deduped by text).
    expect(
        await SyncService.instance.importHighlightsFromArchive(force: true),
        0);
  });

  test('a highlight appended with any editor is imported on next sync',
      () async {
    final file = await ArchiveStore.instance.highlightsFile();
    await file.writeAsString(
        '\n## Kept Article\n\n> added from my laptop\n',
        mode: FileMode.append,
        flush: true);
    // Appending bumps the mtime past the recorded one — no pref fiddling.
    final imported = await SyncService.instance.importHighlightsFromArchive();
    expect(imported, 1);
    final added = (await db.getHighlights())
        .firstWhere((h) => h.text == 'added from my laptop');
    expect(added.articleId, keptArticleId,
        reason: 'matched to the existing article by title');
  });
}
