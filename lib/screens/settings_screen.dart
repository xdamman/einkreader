import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/app_log.dart';
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

  Future<void> _downloadUpdate() async {
    final url = _update?.apkUrl ?? _update?.releaseUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Update available: v${update.latestVersion}  '
          '(installed v${update.currentVersion})',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.download),
          label: Text(
              update.apkUrl != null ? 'Download APK' : 'Open release page'),
          onPressed: _downloadUpdate,
        ),
        const SizedBox(height: 4),
        const Text(
          'Opens GitHub in the browser; tap the file to install over this app.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
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
