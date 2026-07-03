import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
import '../services/backup_service.dart';
import '../services/build_config.dart';
import '../services/nostr_service.dart';
import '../services/sync_service.dart';
import '../services/update_service.dart';

/// Account connections: Twitter (OAuth) and Nostr (public npub only).
class SettingsScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the real GitHub-backed checker.
  final UpdateService? updateService;

  const SettingsScreen({super.key, this.updateService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _db = AppDatabase.instance;
  final _twitter = SyncService.instance.twitter;
  final _clientIdController = TextEditingController();
  final _npubController = TextEditingController();

  bool _twitterConnected = false;
  String? _twitterUsername;
  bool _busy = false;
  bool _developerMode = false;

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    _npubController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final connected = await _twitter.isConnected;
    final username = await _twitter.username;
    final developerMode = await AppLogService.instance.isDeveloperModeEnabled();
    if (!mounted) return;
    setState(() {
      _twitterConnected = connected;
      _twitterUsername = username;
      _clientIdController.text = prefs.getString('twitter_client_id') ?? '';
      _npubController.text = prefs.getString('nostr_npub') ?? '';
      _developerMode = developerMode;
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _connectTwitter() async {
    final clientId = _clientIdController.text.trim();
    if (clientId.isEmpty) {
      _toast('Enter your Twitter OAuth 2.0 Client ID first');
      return;
    }
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('twitter_client_id', clientId);
      final username = await _twitter.connect(clientId);
      final now = DateTime.now().millisecondsSinceEpoch;
      final source = await _db.insertSource(
        Source(
          type: SourceType.twitterBookmarks,
          title: 'Twitter Bookmarks',
          url: username,
          createdAt: now,
        ),
      );
      _toast('Connected as @$username');
      await _load();
      // Pull in this source's items right away.
      unawaited(SyncService.instance.syncSources([source]));
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnectTwitter() async {
    await _twitter.disconnect();
    final sources = await _db.getSources();
    for (final source in sources) {
      if (source.type == SourceType.twitterBookmarks ||
          source.type == SourceType.twitterLikes) {
        await _db.deleteSource(source.id!);
      }
    }
    _toast('Twitter disconnected');
    await _load();
  }

  Future<void> _saveNostr() async {
    final npub = _npubController.text.trim();
    final prefs = await SharedPreferences.getInstance();
    if (npub.isEmpty) {
      await prefs.remove('nostr_npub');
      final sources = await _db.getSources();
      for (final source in sources) {
        if (source.type == SourceType.nostrBookmarks ||
            source.type == SourceType.nostrLikes) {
          await _db.deleteSource(source.id!);
        }
      }
      _toast('Nostr sources removed');
      return;
    }
    try {
      NostrService.decodeNpub(npub); // validate before saving
    } catch (e) {
      _toast('Invalid npub: $e');
      return;
    }
    await prefs.setString('nostr_npub', npub);
    final now = DateTime.now().millisecondsSinceEpoch;
    final bookmarks = await _db.insertSource(
      Source(
        type: SourceType.nostrBookmarks,
        title: 'Nostr Bookmarks',
        url: npub,
        createdAt: now,
      ),
    );
    final likes = await _db.insertSource(
      Source(
        type: SourceType.nostrLikes,
        title: 'Nostr Likes',
        url: npub,
        createdAt: now,
      ),
    );
    _toast('Nostr sources added');
    // Pull in the new sources' items right away.
    unawaited(SyncService.instance.syncSources([bookmarks, likes]));
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
            const Text('Twitter / X', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Creates a feed from your Bookmarks. You need a '
              'free OAuth 2.0 Client ID from developer.x.com with callback '
              'URL einkreader://callback (see README).',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            if (_twitterConnected) ...[
              Text(
                'Connected as @${_twitterUsername ?? '?'}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _disconnectTwitter,
                child: const Text('Disconnect Twitter'),
              ),
            ] else ...[
              TextField(
                controller: _clientIdController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'OAuth 2.0 Client ID',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _connectTwitter,
                child: Text(_busy ? 'Connecting…' : 'Connect Twitter'),
              ),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 24),
            const Text('Nostr', style: sectionStyle),
            const SizedBox(height: 8),
            const Text(
              'Creates two feeds from your public bookmark list and likes. '
              'Only your public key (npub) is needed — never a private key.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _npubController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'npub',
                hintText: 'npub1…',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _saveNostr,
              child: const Text('Save Nostr sources'),
            ),
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
