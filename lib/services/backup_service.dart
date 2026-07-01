import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import 'archive_store.dart';

/// Exports and restores everything the reader keeps locally — the SQLite
/// database and the offline `archive/` directory — as a single `.zip`, so the
/// library survives an uninstall/reinstall. The user shares the zip out (e.g.
/// to Google Drive) and picks it back on restore.
class BackupService {
  static const dbEntry = 'einkreader.db';
  static const archivePrefix = 'archive/';
  static const manifestEntry = 'backup.json';

  final AppDatabase _db;
  final ArchiveStore _store;

  BackupService({AppDatabase? database, ArchiveStore? store})
      : _db = database ?? AppDatabase.instance,
        _store = store ?? ArchiveStore.instance;

  /// Builds a backup zip and returns it. [nowMs] stamps the manifest; the zip
  /// is written to [outputDir] (defaults to the temp directory).
  Future<File> createBackup({required int nowMs, Directory? outputDir}) async {
    await _db.checkpoint();
    final archive = Archive();

    final dbFile = File(await _db.databaseFile());
    if (dbFile.existsSync()) {
      final bytes = dbFile.readAsBytesSync();
      archive.addFile(ArchiveFile(dbEntry, bytes.length, bytes));
    }

    final baseDir = await _store.baseDir();
    final base = Directory(baseDir);
    if (base.existsSync()) {
      for (final entity in base.listSync(recursive: true)) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: baseDir);
        final bytes = entity.readAsBytesSync();
        archive.addFile(
            ArchiveFile('$archivePrefix$rel', bytes.length, bytes));
      }
    }

    final manifest = utf8.encode(jsonEncode({
      'app': 'einkreader',
      'createdAt': nowMs,
      'files': archive.length,
    }));
    archive.addFile(ArchiveFile(manifestEntry, manifest.length, manifest));

    final dir = outputDir ?? await getTemporaryDirectory();
    final out = File(p.join(dir.path, 'einkreader-backup.zip'));
    out.writeAsBytesSync(ZipEncoder().encode(archive));
    return out;
  }

  /// True if [zip] looks like one of our backups (has the db + manifest).
  bool isValidBackup(Archive zip) =>
      zip.files.any((f) => f.name == dbEntry) &&
      zip.files.any((f) => f.name == manifestEntry);

  /// Replaces the current database and archive with the contents of [zipFile].
  /// Destructive: the existing library is wiped first. Throws if the zip isn't
  /// a valid einkreader backup.
  Future<void> restoreBackup(File zipFile) async {
    final zip = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
    if (!isValidBackup(zip)) {
      throw const FormatException('Not an einkreader backup file');
    }

    final dbPath = await _db.databaseFile();
    final baseDir = await _store.baseDir();

    await _db.close();

    // Clear the old library so nothing stale survives the restore.
    final base = Directory(baseDir);
    if (base.existsSync()) base.deleteSync(recursive: true);
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }

    for (final file in zip.files) {
      if (!file.isFile) continue;
      final data = file.content as List<int>;
      if (file.name == dbEntry) {
        File(dbPath).writeAsBytesSync(data);
      } else if (file.name.startsWith(archivePrefix)) {
        final out =
            File(p.join(baseDir, file.name.substring(archivePrefix.length)));
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(data);
      }
    }
    // The db reopens from the restored file on next access; the archive path is
    // unchanged (same location, just repopulated), so no cache reset needed.
  }
}
