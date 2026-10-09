import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import 'archive_store.dart';

/// When and how big the last successful backup was.
class LastBackup {
  final DateTime at;
  final int bytes;
  const LastBackup(this.at, this.bytes);
}

/// Exports and restores everything the reader keeps locally — the SQLite
/// database and the offline `archive/` directory — as a single `.zip`, so the
/// library survives an uninstall/reinstall. The user shares the zip out (e.g.
/// to Google Drive) and picks it back on restore.
///
/// Zipping and unzipping run in a background isolate and stream file by file,
/// so a large library neither freezes the UI ("isn't responding") nor has to
/// fit in memory. Progress is reported as a 0..1 fraction of bytes processed.
class BackupService {
  static const dbEntry = 'einkreader.db';
  static const archivePrefix = 'archive/';
  static const manifestEntry = 'backup.json';
  static const _kLastAt = 'last_backup_at';
  static const _kLastBytes = 'last_backup_bytes';

  final AppDatabase _db;
  final ArchiveStore _store;

  BackupService({AppDatabase? database, ArchiveStore? store})
      : _db = database ?? AppDatabase.instance,
        _store = store ?? ArchiveStore.instance;

  /// Builds a backup zip and returns it. [nowMs] stamps the manifest; the zip
  /// is written to [outputDir] (defaults to the temp directory).
  Future<File> createBackup(
      {required int nowMs,
      Directory? outputDir,
      void Function(double progress)? onProgress}) async {
    await _db.checkpoint();
    final dbPath = await _db.databaseFile();
    final baseDir = await _store.baseDir();
    final dir = outputDir ?? await getTemporaryDirectory();
    final outPath = p.join(dir.path, 'einkreader-backup.zip');
    await _zipInBackground(dbPath, baseDir, outPath, nowMs, onProgress);
    return File(outPath);
  }

  /// Remembers a backup the user actually saved, for "Last backup: …".
  Future<void> recordBackup(File zip, {DateTime? at}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _kLastAt, (at ?? DateTime.now()).millisecondsSinceEpoch);
    await prefs.setInt(_kLastBytes, zip.existsSync() ? zip.lengthSync() : 0);
  }

  Future<LastBackup?> lastBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_kLastAt);
    if (at == null) return null;
    return LastBackup(DateTime.fromMillisecondsSinceEpoch(at),
        prefs.getInt(_kLastBytes) ?? 0);
  }

  /// True if [zip] looks like one of our backups (has the db + manifest).
  static bool isValidBackup(Archive zip) =>
      zip.files.any((f) => f.name == dbEntry) &&
      zip.files.any((f) => f.name == manifestEntry);

  /// Replaces the current database and archive with the contents of [zipFile].
  /// Destructive: the existing library is wiped first. Throws if the zip isn't
  /// a valid einkreader backup (checked before anything is touched).
  Future<void> restoreBackup(File zipFile,
      {void Function(double progress)? onProgress}) async {
    final zipPath = zipFile.path;
    if (!await _isValidInBackground(zipPath)) {
      throw const FormatException('Not an einkreader backup file');
    }

    final dbPath = await _db.databaseFile();
    final baseDir = await _store.baseDir();
    await _db.close();
    // The db reopens from the restored file on next access; the archive path
    // is unchanged (same location, just repopulated), so no cache reset.
    await _unzipInBackground(zipPath, dbPath, baseDir, onProgress);
  }

  // The isolate entry points are built in static methods so their closures
  // capture only plain strings and ports, never this service (whose database
  // handle cannot be sent to another isolate).

  static Future<bool> _isValidInBackground(String zipPath) =>
      Isolate.run(() {
      final input = InputFileStream(zipPath);
      try {
        return isValidBackup(ZipDecoder().decodeStream(input));
      } catch (_) {
        return false;
      } finally {
        input.closeSync();
      }
    });

  static Future<void> _zipInBackground(String dbPath, String baseDir,
          String outPath, int nowMs, void Function(double)? onProgress) =>
      _inIsolate(
          (port) => _zip(dbPath, baseDir, outPath, nowMs, port), onProgress);

  static Future<void> _unzipInBackground(String zipPath, String dbPath,
          String baseDir, void Function(double)? onProgress) =>
      _inIsolate((port) => _unzip(zipPath, dbPath, baseDir, port), onProgress);

  /// Runs [work] in a background isolate, forwarding its progress messages.
  /// Errors thrown in the isolate surface here.
  static Future<void> _inIsolate(void Function(SendPort) work,
      void Function(double)? onProgress) async {
    final port = ReceivePort();
    port.listen((message) {
      if (message is double) onProgress?.call(message);
    });
    try {
      await _run(work, port.sendPort);
    } finally {
      port.close();
    }
  }

  // Separate so the isolate closure's context holds only [work] and [send],
  // not the caller's progress callback (which may reference widgets).
  static Future<void> _run(void Function(SendPort) work, SendPort send) =>
      Isolate.run(() => work(send));

  /// Sends progress in whole-percent steps so the UI (and e-ink) only
  /// repaints when the number visibly changes.
  static void Function(int done) _reporter(int total, SendPort port) {
    var lastPct = -1;
    return (done) {
      final pct = total == 0 ? 100 : (done * 100 ~/ total).clamp(0, 100);
      if (pct == lastPct) return;
      lastPct = pct;
      port.send(pct / 100);
    };
  }

  static void _zip(String dbPath, String baseDir, String outPath, int nowMs,
      SendPort port) {
    final entries = <String, File>{};
    final dbFile = File(dbPath);
    if (dbFile.existsSync()) entries[dbEntry] = dbFile;
    final base = Directory(baseDir);
    if (base.existsSync()) {
      for (final entity in base.listSync(recursive: true)) {
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: baseDir);
        entries['$archivePrefix${p.posix.joinAll(p.split(rel))}'] = entity;
      }
    }
    final sizes = {for (final e in entries.entries) e.key: e.value.lengthSync()};
    final total = sizes.values.fold<int>(0, (a, b) => a + b);
    final report = _reporter(total, port);

    final out = File(outPath);
    if (out.existsSync()) out.deleteSync();
    final encoder = ZipFileEncoder()..create(outPath);
    var done = 0;
    report(0);
    try {
      for (final e in entries.entries) {
        encoder.addFileSync(e.value, e.key);
        done += sizes[e.key]!;
        report(done);
      }
      final manifest = utf8.encode(jsonEncode({
        'app': 'einkreader',
        'createdAt': nowMs,
        'files': entries.length + 1,
      }));
      encoder.addArchiveFile(
          ArchiveFile(manifestEntry, manifest.length, manifest));
    } finally {
      encoder.closeSync();
    }
  }

  static void _unzip(
      String zipPath, String dbPath, String baseDir, SendPort port) {
    final input = InputFileStream(zipPath);
    try {
      final zip = ZipDecoder().decodeStream(input);

      // Clear the old library so nothing stale survives the restore.
      final base = Directory(baseDir);
      if (base.existsSync()) base.deleteSync(recursive: true);
      for (final suffix in ['', '-wal', '-shm']) {
        final f = File('$dbPath$suffix');
        if (f.existsSync()) f.deleteSync();
      }

      final files = zip.files.where((f) => f.isFile).toList();
      final total = files.fold<int>(0, (a, f) => a + f.size);
      final report = _reporter(total, port);
      var done = 0;
      report(0);
      for (final file in files) {
        String? outPath;
        if (file.name == dbEntry) {
          outPath = dbPath;
        } else if (file.name.startsWith(archivePrefix)) {
          outPath = p.join(baseDir, file.name.substring(archivePrefix.length));
        }
        if (outPath != null) {
          File(outPath).parent.createSync(recursive: true);
          final out = OutputFileStream(outPath);
          try {
            file.writeContent(out);
          } finally {
            out.closeSync();
          }
        }
        done += file.size;
        report(done);
      }
    } finally {
      input.closeSync();
    }
  }
}
