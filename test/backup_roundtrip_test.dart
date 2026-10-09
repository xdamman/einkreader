// A backup zip round-trips the database + offline archive: after wiping
// everything and restoring, the sources, articles and archive files are back.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/screens/settings_screen.dart';
import 'package:einkreader/services/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;

    tmp = await Directory.systemTemp.createTemp('einkbackup');
    AppDatabase.instance.debugDatabasePath = p.join(tmp.path, 'einkreader.db');
    await AppDatabase.instance.debugReset();
    ArchiveStore.instance
        .debugConfigure(basePath: p.join(tmp.path, 'archive'));
  });

  tearDown(() async {
    await AppDatabase.instance.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('backup then restore recovers db rows and archive files', () async {
    final db = AppDatabase.instance;
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 1));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'g1',
      title: 'Hello',
      contentMarkdown: 'Body',
      createdAt: 1,
    ));

    // A file in the offline archive dir.
    final archiveBase = await ArchiveStore.instance.baseDir();
    final archived = File(p.join(archiveBase, '2026', 'note.md'));
    archived.parent.createSync(recursive: true);
    archived.writeAsStringSync('archived content');

    final backup = BackupService();
    final progress = <double>[];
    final zip = await backup.createBackup(
        nowMs: 1234, outputDir: tmp, onProgress: progress.add);
    expect(zip.existsSync(), isTrue);
    // Zipped in a background isolate, reporting progress up to done.
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    expect(progress, orderedEquals([...progress]..sort()));

    // Wipe everything: delete all sources (cascades) and the archive dir.
    for (final s in await db.getSources()) {
      await db.deleteSource(s.id!);
    }
    Directory(archiveBase).deleteSync(recursive: true);
    expect(await db.getSources(), isEmpty);

    final restoreProgress = <double>[];
    await backup.restoreBackup(zip, onProgress: restoreProgress.add);
    expect(restoreProgress.last, 1.0);

    // DB rows are back.
    final sources = await db.getSources();
    expect(sources.map((s) => s.title), ['Feed']);
    final articles = await db.getArticles();
    expect(articles.map((a) => a.title), ['Hello']);

    // Archive file is back with its content.
    final restored = File(p.join(await ArchiveStore.instance.baseDir(),
        '2026', 'note.md'));
    expect(restored.existsSync(), isTrue);
    expect(restored.readAsStringSync(), 'archived content');
  });

  test('remembers the last backup, with its size', () async {
    final backup = BackupService();
    expect(await backup.lastBackup(), isNull);
    final zip = await backup.createBackup(nowMs: 1, outputDir: tmp);
    await backup.recordBackup(zip, at: DateTime(2026, 10, 9, 14, 5));
    final last = await backup.lastBackup();
    expect(last!.at, DateTime(2026, 10, 9, 14, 5));
    expect(last.bytes, zip.lengthSync());
  });

  test('last backup label', () {
    final now = DateTime(2026, 10, 9, 18);
    expect(SettingsScreenLabels.lastBackup(null, now: now), 'No backup yet.');
    expect(
        SettingsScreenLabels.lastBackup(
            LastBackup(DateTime(2026, 10, 9, 14, 5), 3 * 1024 * 1024),
            now: now),
        'Last backup: today at 14:05 (3.0 MB)');
    expect(
        SettingsScreenLabels.lastBackup(
            LastBackup(DateTime(2026, 10, 8, 9, 30), 2048),
            now: now),
        'Last backup: yesterday at 09:30 (2 KB)');
    expect(
        SettingsScreenLabels.lastBackup(
            LastBackup(DateTime(2026, 9, 1, 8, 0), 0),
            now: now),
        'Last backup: 1 Sep 2026 at 08:00');
  });

  test('rejects a zip that is not an einkreader backup', () async {
    final bogus = File(p.join(tmp.path, 'bogus.zip'))
      ..writeAsBytesSync([0x50, 0x4b, 0x03, 0x04]); // empty-ish zip header
    expect(
      () => BackupService().restoreBackup(bogus),
      throwsA(anything),
    );
  });
}
