import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../services/app_log.dart';
import '../services/archive_store.dart';
import '../services/backup_service.dart';
import '../services/build_config.dart';
import '../services/sync_service.dart';
import '../services/update_service.dart';
import '../services/plugin_service.dart';
import '../widgets/relay_settings.dart';
import 'contacts_screen.dart';
import 'plugin_pitch_screen.dart';
import 'sources_screen.dart';

/// App settings: source management entry point, storage location, backup /
/// restore and developer tools. Accounts (Twitter, Nostr) are connected from
/// the Add source screen.
class SettingsScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the real GitHub-backed checker.
  final UpdateService? updateService;

  const SettingsScreen({super.key, this.updateService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _developerMode = false;
  bool _supporter = false;
  bool _twitterPluginOn = false;
  bool _emailPluginOn = false;

  late final _updates = widget.updateService ?? UpdateService();
  UpdateInfo? _update;
  bool _checkingUpdate = false;

  /// Download progress as a whole percent while installing an update; null when
  /// not downloading. Updated in 5% steps so e-ink repaints stay discrete.
  int? _downloadPct;

  final _backupService = BackupService();

  /// Separate flags so backing up only relabels its own button; both buttons
  /// are still disabled while either operation runs.
  bool _backingUp = false;
  bool _restoring = false;
  bool get _backupBusy => _backingUp || _restoring;

  /// Where the offline archive currently lives, and whether that is a
  /// user-chosen folder (as opposed to the default app directory).
  String? _archiveDir;
  bool _customArchiveDir = false;
  bool _movingArchive = false;
  bool _tidying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final developerMode = await AppLogService.instance.isDeveloperModeEnabled();
    final archiveDir = await ArchiveStore.instance.baseDir();
    final supporter = await PluginService.instance.isSupporter;
    final twitterOn = await PluginService.instance.twitterOn;
    final emailOn = await PluginService.instance.emailOn;
    if (!mounted) return;
    setState(() {
      _developerMode = developerMode;
      _archiveDir = archiveDir;
      _customArchiveDir = prefs.getString(ArchiveStore.dirPrefKey) != null;
      _supporter = supporter;
      _twitterPluginOn = twitterOn;
      _emailPluginOn = emailOn;
    });
    if (developerMode && _update == null) _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = await _updates.check();
      if (!mounted) return;
      setState(() => _update = update);
    } catch (e) {
      if (mounted) _toast('Update check failed: $e');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// Opens the release/APK URL in the browser (fallback when in-app install
  /// isn't available, e.g. no apk asset).
  Future<void> _openInBrowser() async {
    final url = _update?.apkUrl ?? _update?.releaseUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Sideload-only: download the APK (with discrete progress) and hand it to the
  /// system installer, which prompts the user to confirm the update.
  Future<void> _downloadAndInstall() async {
    final update = _update;
    if (update == null || _downloadPct != null) return;
    setState(() => _downloadPct = 0);
    try {
      final path = await _updates.downloadApk(update, onProgress: (p) {
        final pct = (p * 100).floor();
        // Only repaint on a new 5% step — keeps e-ink refreshes discrete.
        if (_downloadPct == null || pct >= _downloadPct! + 5 || pct == 100) {
          setState(() => _downloadPct = pct);
        }
      });
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && mounted) {
        _toast('Could not open installer: ${result.message}');
      }
    } catch (e) {
      if (mounted) _toast('Update failed: $e');
    } finally {
      if (mounted) setState(() => _downloadPct = null);
    }
  }

  Future<void> _backup() async {
    setState(() => _backingUp = true);
    try {
      final file = await _backupService.createBackup(
          nowMs: DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path)],
          subject: 'einkreader backup', text: 'einkreader library backup');
    } catch (e) {
      if (mounted) _toast('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
        title: const Text('Restore backup?'),
        content: const Text(
            'This replaces your current library — feeds, articles, highlights '
            'and downloaded content — with the backup. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _restoring = true);
    try {
      await _backupService.restoreBackup(File(path));
      if (!mounted) return;
      await _load();
      _toast('Backup restored');
    } catch (e) {
      if (mounted) _toast('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// Best-effort storage permission: Android 11+ needs "All files access" for
  /// raw paths outside the app; older versions use the legacy permission. The
  /// real authority is the write probe in [ArchiveStore.moveTo] — if writing
  /// works without any grant (e.g. an app-specific external dir), fine.
  Future<void> _requestStoragePermission() async {
    if (!Platform.isAndroid) return;
    var status = await Permission.manageExternalStorage.status;
    if (status.isGranted) return;
    status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return;
    await Permission.storage.request();
  }

  Future<void> _moveArchive(String? path) async {
    if (SyncService.instance.isSyncing) {
      _toast('Wait for the current sync to finish first');
      return;
    }
    setState(() => _movingArchive = true);
    try {
      await ArchiveStore.instance.moveTo(path);
      await _load();
      _toast(path == null
          ? 'Library moved back to app storage'
          : 'Library moved');
    } catch (e) {
      _toast('Could not move the library: $e');
    } finally {
      if (mounted) setState(() => _movingArchive = false);
    }
  }

  Future<void> _tidyArchive() async {
    if (SyncService.instance.isSyncing) {
      _toast('Wait for the current sync to finish first');
      return;
    }
    setState(() => _tidying = true);
    try {
      final moved = await ArchiveStore.instance.tidyArchive();
      final rewritten =
          await AppDatabase.instance.stripMonthFromImageRefs();
      _toast(moved == 0
          ? 'Archive already tidy'
          : 'Tidied: moved $moved files'
              '${rewritten > 0 ? ', updated $rewritten articles' : ''}');
    } catch (e) {
      _toast('Tidy failed: $e');
    } finally {
      if (mounted) setState(() => _tidying = false);
    }
  }

  Future<void> _chooseArchiveDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose the library folder',
    );
    if (path == null) return;
    await _requestStoragePermission();
    await _moveArchive(path);
  }

  Widget _buildUpdateTile() {
    if (_checkingUpdate) {
      return const Text('Checking for updates…',
          style: TextStyle(fontSize: 14));
    }
    final update = _update;
    if (update == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: _checkForUpdate,
          child: const Text('Check for updates'),
        ),
      );
    }
    if (!update.updateAvailable) {
      return Row(
        children: [
          Expanded(
            child: Text('Up to date (v${update.currentVersion})',
                style: const TextStyle(fontSize: 14)),
          ),
          TextButton(
              onPressed: _checkForUpdate, child: const Text('Check again')),
        ],
      );
    }

    final header = Text(
      'Update available: v${update.latestVersion}  '
      '(installed v${update.currentVersion})',
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );

    // Play Store build: the store handles updates; don't offer a sideload path.
    if (!kSelfUpdateSupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 4),
          const Text('Update through the Play Store.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
        ],
      );
    }

    if (_downloadPct != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 8),
          Text('Downloading… $_downloadPct%',
              style: const TextStyle(fontSize: 14)),
        ],
      );
    }

    final canInstall = update.apkUrl != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.download),
          label: Text(canInstall ? 'Download & install' : 'Open release page'),
          onPressed: canInstall ? _downloadAndInstall : _openInBrowser,
        ),
        const SizedBox(height: 4),
        Text(
          canInstall
              ? 'Downloads and launches the installer; you confirm the update.'
              : 'Opens the release page in the browser.',
          style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  Future<void> _openPitch() async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PluginPitchScreen()));
    _load();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    const sectionStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Sources', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Manage your feeds and organize them into folders.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.rss_feed),
              label: const Text('Manage sources'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourcesScreen())),
            ),
            const Text('Plugins', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'einkreader is free forever. Plugins run on our servers and '
              'need the supporter subscription.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            _PluginCard(
              title: '@ Twitter',
              description: 'Sync your bookmarks as a source · share '
                  'highlights as tweets & quote-tweets',
              enabled: _supporter,
              on: _twitterPluginOn,
              onChanged: (v) async {
                await PluginService.instance.setTwitterOn(v);
                _load();
              },
              onLockedTap: _openPitch,
            ),
            const SizedBox(height: 10),
            _PluginCard(
              title: '✉ Email',
              description: 'Send anything to your @einkreader.app address '
                  'to read it · one-tap shares from your address',
              enabled: _supporter,
              on: _emailPluginOn,
              onChanged: (v) async {
                await PluginService.instance.setEmailOn(v);
                _load();
              },
              onLockedTap: _openPitch,
            ),
            const SizedBox(height: 12),
            if (!_supporter)
              OutlinedButton(
                onPressed: _openPitch,
                child: const Text('Subscribe to activate plugins'),
              )
            else
              const Text('Supporter · early access',
                  style: TextStyle(
                      fontSize: 12, fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.people_outline),
              label: const Text('Contacts'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ContactsScreen())),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Nostr relays', style: sectionStyle),
            const SizedBox(height: 8),
            const RelaySettings(),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            if (kCustomStorageSupported) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 24),
              const Text('Storage', style: sectionStyle),
              const SizedBox(height: 8),
              const Text(
                'Where your offline library (article files and images) is '
                'stored. Choose a folder outside the app — for example one '
                'synced by Syncthing — to mirror it to your other devices. '
                'The reading database itself stays in app storage.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Everything is stored as plain Markdown files in a clear '
                'directory structure — a folder per year, then per source '
                '(so archiving a year is moving one folder), a favorites '
                'copy, and a single highlights.md — easy to back up, '
                'restore and browse with any application. highlights.md '
                'works both ways: highlights added to it with any editor '
                'are imported into the app on the next sync.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _archiveDir == null
                          ? 'Current folder: …'
                          : 'Current folder: $_archiveDir'
                              '${_customArchiveDir ? '' : ' (app storage)'}',
                      style: const TextStyle(
                          fontSize: 13, fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open folder',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: _archiveDir == null
                        ? null
                        : () => OpenFilex.open(_archiveDir!),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open),
                label: Text(_movingArchive ? 'Moving…' : 'Choose folder'),
                onPressed: _movingArchive ? null : _chooseArchiveDir,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.cleaning_services_outlined),
                label: Text(_tidying ? 'Tidying…' : 'Tidy archive'),
                onPressed: _tidying ? null : _tidyArchive,
              ),
              const SizedBox(height: 4),
              const Text(
                'Folds older year/month folders into the year/source '
                'layout and collects stray year folders left next to the '
                'archive by earlier versions.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
              if (_customArchiveDir) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.undo),
                  label: const Text('Move back to app storage'),
                  onPressed: _movingArchive ? null : () => _moveArchive(null),
                ),
              ],
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Backup', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Save your whole library (feeds, articles, highlights and '
              'downloaded content) to a file you can keep in Google Drive, then '
              'restore it after reinstalling.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.backup_outlined),
              label: Text(_backingUp ? 'Preparing…' : 'Back up now'),
              onPressed: _backupBusy ? null : _backup,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: Text(_restoring ? 'Restoring…' : 'Restore from backup'),
              onPressed: _backupBusy ? null : _restore,
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Developer', style: sectionStyle),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Developer mode'),
              subtitle: const Text('Show the Debug tab on the reader screen.'),
              value: _developerMode,
              onChanged: (value) async {
                setState(() => _developerMode = value);
                await AppLogService.instance.setDeveloperModeEnabled(value);
                if (value) _checkForUpdate();
              },
            ),
            if (_developerMode) ...[
              const SizedBox(height: 8),
              _buildUpdateTile(),
            ],
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'einkreader — a minimal offline reader for e-ink devices.\n'
              'All content is stored on this device.',
              style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plugin card: capabilities in plain words, a toggle that is inert until
/// the subscription unlocks it (tapping then opens the pitch).
class _PluginCard extends StatelessWidget {
  final String title;
  final String description;
  final bool enabled;
  final bool on;
  final ValueChanged<bool> onChanged;
  final VoidCallback onLockedTap;

  const _PluginCard({
    required this.title,
    required this.description,
    required this.enabled,
    required this.on,
    required this.onChanged,
    required this.onLockedTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? null : onLockedTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(description, style: const TextStyle(fontSize: 12.5)),
                  if (!enabled)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('requires subscription',
                          style: TextStyle(
                              fontSize: 11, fontStyle: FontStyle.italic)),
                    ),
                ],
              ),
            ),
            Switch(
              value: on && enabled,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}
