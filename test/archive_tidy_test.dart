// Tidy: folds the legacy YYYY/MM/source layout into YYYY/source, adopts
// stray legacy year trees left in the base's parent folder (earlier archive
// locations / interrupted moves), and the db rewrite updates stored
// eink-img:// references to the folded paths.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test('tidy folds months, adopts strays, and refs are rewritten', () async {
    final parent = Directory.systemTemp.createTempSync('einkreader_tidy');
    final base = Directory(p.join(parent.path, 'Reads'))..createSync();
    // The base is a user-chosen folder (enables the stray sweep).
    SharedPreferences.setMockInitialValues(
        {ArchiveStore.dirPrefKey: base.path});
    ArchiveStore.instance.debugConfigure(basePath: base.path);
    AppDatabase.instance.debugDatabasePath = p.join(parent.path, 'test.db');
    await AppDatabase.instance.debugReset();

    File write(String path) => File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('content of $path');

    // Legacy month layout inside the base.
    write(p.join(base.path, '2026', '06', 'stratechery', 'a.md'));
    write(p.join(
        base.path, '2026', '06', 'stratechery', 'images', 'img1.jpg'));
    write(p.join(base.path, '2026', '07', 'stratechery', 'b.md'));
    write(p.join(base.path, '2025', '12', 'favorites', 'c.md'));
    // A stray legacy tree next to the base (earlier archive location).
    write(p.join(parent.path, '2026', '06', 'bx1', 'd.md'));
    // A year-named folder without month dirs must NOT be touched.
    write(p.join(parent.path, '2024', 'unrelated.txt'));
    // highlights.md stays where it is.
    write(p.join(base.path, 'highlights.md'));

    // An article whose stored content references the legacy image path.
    final db = AppDatabase.instance;
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Stratechery', url: 'x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'g1',
      title: 'A',
      contentMarkdown:
          'Text ![alt](eink-img://2026/06/stratechery/images/img1.jpg)',
      fetched: 1,
      createdAt: 1,
    ));

    final moved = await ArchiveStore.instance.tidyArchive();
    expect(moved, 5);

    // Month layer folded away, strays adopted, unrelated folder untouched.
    expect(
        File(p.join(base.path, '2026', 'stratechery', 'a.md')).existsSync(),
        isTrue);
    expect(
        File(p.join(base.path, '2026', 'stratechery', 'images', 'img1.jpg'))
            .existsSync(),
        isTrue);
    expect(
        File(p.join(base.path, '2026', 'stratechery', 'b.md')).existsSync(),
        isTrue);
    expect(File(p.join(base.path, '2025', 'favorites', 'c.md')).existsSync(),
        isTrue);
    expect(File(p.join(base.path, '2026', 'bx1', 'd.md')).existsSync(),
        isTrue);
    expect(Directory(p.join(parent.path, '2026')).existsSync(), isFalse);
    expect(File(p.join(parent.path, '2024', 'unrelated.txt')).existsSync(),
        isTrue);
    expect(Directory(p.join(base.path, '2026', '06')).existsSync(), isFalse);
    expect(File(p.join(base.path, 'highlights.md')).existsSync(), isTrue);

    // Stored references follow the moved files.
    final rewritten = await db.stripMonthFromImageRefs();
    expect(rewritten, 1);
    final article = (await db.getArticles(sourceId: source.id)).single;
    expect(article.contentMarkdown,
        contains('eink-img://2026/stratechery/images/img1.jpg'));

    // A second run is a no-op.
    expect(await ArchiveStore.instance.tidyArchive(), 0);
    await AppDatabase.instance.debugReset();
  });
}
