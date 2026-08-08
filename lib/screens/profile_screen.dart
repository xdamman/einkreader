import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';

import '../db/app_database.dart';
import '../models.dart';
import '../services/profile_service.dart';

/// The profile, full screen (never a modal: one clean e-ink repaint, back =
/// "not now"). First visit is the opt-in with a single name field; once
/// created, the screen teaches itself — every empty element says what it
/// becomes when tapped. Fields auto-save; the profile publishes on leave.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _profileService = ProfileService.instance;
  bool? _enabled; // null while loading
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _about = TextEditingController();
  final _links = TextEditingController();
  String _picture = '';
  String? _address;
  bool _addressPending = false;
  bool _uploading = false;
  bool _creating = false;

  /// The screen opens read-only; editing is behind the Edit button. A
  /// freshly created profile starts in edit mode (everything is empty).
  bool _editing = false;
  bool _usernameEdited = false;
  bool _dirty = false;
  String? _usernameError;

  /// Import-on-create: offered when the previous profile has sources.
  String? _importFrom;
  List<Source> _importableSources = [];
  bool _importChecked = true;

  /// null = all sources; otherwise the customized subset.
  Set<int>? _importSourceIds;

  /// What this profile has shared (from the local Shared record — visible
  /// immediately, even while a publish still waits in the outbox).
  List<Share> _sharedHighlights = [];

  @override
  void initState() {
    super.initState();
    _load();
    // Suggest a username from the name as they type, until they take over.
    _name.addListener(() {
      if (_enabled == false && !_usernameEdited) {
        _username.text = ProfileService.suggestUsername(_name.text);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _about.dispose();
    _links.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await _profileService.enabled;
    if (!enabled) {
      // A fresh slot can bring the previous profile's data along.
      final from = await _profileService.previousProfileId;
      final activeId = AppDatabase.instance.activeProfile;
      if (from != null && from != activeId) {
        _importFrom = from;
        _importableSources =
            await AppDatabase.instance.getSourcesOf(from);
      }
    }
    if (enabled) {
      final profile = await _profileService.profile();
      _name.text = profile.name;
      _about.text = profile.about;
      _links.text = profile.links;
      _picture = profile.picture;
      _address = await _profileService.nip05Address;
      _addressPending = await _profileService.username == null;
      // One entry per highlight, newest first (a highlight shared to both
      // the profile and as a link appears once). Best-effort: the profile
      // fields must render even if the database is unavailable.
      try {
        final seen = <int>{};
        _sharedHighlights = [
          for (final share in await AppDatabase.instance.getShares())
            if ((share.medium == 'profile' || share.medium == 'link') &&
                seen.add(share.highlightId))
              share,
        ];
      } catch (_) {
        _sharedHighlights = [];
      }
    }
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  Future<void> _create() async {
    final username = _username.text.trim();
    if (!ProfileService.usernameRule.hasMatch(username)) {
      setState(() =>
          _usernameError = 'At least 5 characters: a–z, 0–9 and _ only');
      return;
    }
    setState(() {
      _usernameError = null;
      _creating = true;
    });
    await _profileService.createIdentity();
    try {
      // Offline just means "pending": creation always succeeds locally.
      await _profileService.registerUsername(username);
    } on UsernameTakenException {
      if (!mounted) return;
      setState(() {
        _usernameError = '"$username" is taken — pick another';
        _creating = false;
      });
      return;
    }
    await _profileService.saveProfile(Profile(name: _name.text.trim()));
    if (_importChecked && _importFrom != null &&
        _importableSources.isNotEmpty) {
      final imported = await AppDatabase.instance.importProfileData(
          fromProfile: _importFrom!, onlySourceIds: _importSourceIds);
      if (mounted && imported > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Imported $imported feed'
                '${imported == 1 ? '' : 's'} with their highlights')));
      }
    }
    if (!mounted) return;
    setState(() {
      _creating = false;
      _editing = true;
    });
    await _load();
  }

  /// Per-source selection for the import: unchecked sources bring neither
  /// their feed nor their highlights.
  Future<void> _customizeImport() async {
    final selected = Set<int>.from(
        _importSourceIds ?? _importableSources.map((s) => s.id!));
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape:
              const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
          title: const Text('Import from'),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final source in _importableSources)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: selected.contains(source.id),
                    title: Text(source.title),
                    onChanged: (checked) => setDialogState(() {
                      if (checked == true) {
                        selected.add(source.id!);
                      } else {
                        selected.remove(source.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: const Text('Done')),
          ],
        ),
      ),
    );
    if (result == null) return;
    setState(() => _importSourceIds =
        result.length == _importableSources.length ? null : result);
  }

  /// Test hook for the auto-save path (pop callbacks don't run in tests).
  @visibleForTesting
  Future<void> debugPersistForTest() => _persist();

  /// Auto-save: fields persist (and publish, debounced by the pop) without a
  /// Save button. Offline the kind-0 update waits in the outbox — editing
  /// never needs a connection.
  Future<int?> _persist() async {
    if (_enabled != true || !_dirty) return null;
    _dirty = false;
    return _profileService.saveProfile(Profile(
      name: _name.text.trim(),
      about: _about.text.trim(),
      picture: _picture,
      links: _links.text.trim(),
    ));
  }

  /// Done editing: save, report where the update went, back to the view.
  Future<void> _finishEditing() async {
    final accepted = await _persist();
    if (!mounted) return;
    setState(() => _editing = false);
    if (accepted != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(accepted > 0
              ? 'Profile published'
              : 'Profile saved — publishing when back online')));
    }
  }

  Future<void> _pickAvatar() async {
    if (_uploading) return;
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final resized = await Isolate.run(() => _shrink(bytes));
      final url = await _profileService.uploadAvatar(resized);
      if (!mounted) return;
      setState(() {
        _picture = url;
        _dirty = true;
      });
      await _persist();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Avatar upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  static Uint8List _shrink(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longest > 512
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? 512 : null,
            height: decoded.height > decoded.width ? 512 : null,
          )
        : decoded;
    return img.encodeJpg(resized, quality: 85);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back from edit mode returns to the view (saving); back from the
      // view leaves the screen.
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _persist();
        } else if (_editing) {
          _finishEditing();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title:
              Text(_enabled == true ? 'Your profile' : 'Create a profile'),
          actions: [
            if (_enabled == true && !_editing)
              IconButton(
                tooltip: 'Edit profile',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => setState(() => _editing = true),
              ),
            if (_enabled == true && _editing)
              IconButton(
                tooltip: 'Done',
                icon: const Icon(Icons.check),
                onPressed: _finishEditing,
              ),
            if (_enabled == true && _address != null)
              IconButton(
                tooltip: 'Open your public page',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => launchUrl(
                    Uri.parse(
                        'https://einkreader.app/${_address!.split('@').first}'),
                    mode: LaunchMode.externalApplication),
              ),
          ],
        ),
        body: switch (_enabled) {
          null => const SizedBox.shrink(),
          false => _optIn(),
          true => _editing ? _editor() : _viewer(),
        },
      ),
    );
  }

  Widget _optIn() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      width: 2, style: BorderStyle.solid, color: Colors.black),
                ),
                child: const Text('?',
                    style: TextStyle(
                        fontSize: 40, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 20),
              const Text(
                'Would you like to create a public profile?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'einkreader is private and local-first: nothing leaves this '
                'device unless you share it. A profile lets you share chosen '
                'highlights and comments — you pick what to share, every '
                'time.',
                style: TextStyle(fontSize: 15, height: 1.45),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _username,
                autocorrect: false,
                onChanged: (_) => _usernameEdited = true,
                decoration: InputDecoration(
                  labelText: 'Username',
                  suffixText: '@einkreader.app',
                  errorText: _usernameError,
                  helperText: 'Your public address — people use it to tag '
                      'and follow you',
                ),
                onSubmitted: (_) => _create(),
              ),
              if (_importFrom != null &&
                  _importableSources.isNotEmpty) ...[
                const SizedBox(height: 14),
                InkWell(
                  onTap: () =>
                      setState(() => _importChecked = !_importChecked),
                  child: Row(
                    children: [
                      Icon(
                          _importChecked
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Bring my feeds & highlights '
                            '(${_importSourceIds?.length ?? _importableSources.length} '
                            'of ${_importableSources.length} sources)',
                            style: const TextStyle(fontSize: 14)),
                      ),
                      if (_importChecked)
                        TextButton(
                          onPressed: _customizeImport,
                          child: const Text('Customize…',
                              style: TextStyle(fontSize: 13)),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),
              OutlinedButton(
                onPressed: _creating ? null : _create,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(width: 2),
                ),
                child: Text(_creating ? 'Creating…' : 'Create profile',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 10),
              const Text(
                'Not now? Just go back — nothing is created.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Read-only profile view — the screen's default face. Everything renders
  /// from local preferences, so it works fully offline (a missing avatar
  /// image quietly falls back to the initial).
  Widget _viewer() {
    final name = _name.text.trim();
    final about = _about.text.trim();
    final links = _links.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: Colors.black,
                  foregroundImage:
                      _picture.isEmpty ? null : NetworkImage(_picture),
                  onForegroundImageError:
                      _picture.isEmpty ? null : (_, __) {},
                  child: Text(initial,
                      style: const TextStyle(
                          fontSize: 34, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(name.isEmpty ? 'Unnamed reader' : name,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700)),
              ),
              if (_address != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(_address!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace')),
                      const SizedBox(height: 4),
                      Text(
                        _addressPending
                            ? 'Registering when back online — this will be '
                                'your address to be tagged and followed'
                            : 'Share this address so people can tag you and '
                                'subscribe to your highlights',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (about.isNotEmpty)
                Text(about,
                    style: const TextStyle(fontSize: 15, height: 1.45))
              else
                const Text('No bio yet — tap Edit to add one.',
                    style: TextStyle(
                        fontSize: 13.5, fontStyle: FontStyle.italic)),
              if (links.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final link in links)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: InkWell(
                      onTap: () => launchUrl(Uri.parse(link),
                          mode: LaunchMode.externalApplication),
                      child: Text(link,
                          style: const TextStyle(
                              fontSize: 13.5,
                              decoration: TextDecoration.underline)),
                    ),
                  ),
              ],
              const SizedBox(height: 22),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit profile'),
                onPressed: () => setState(() => _editing = true),
              ),
              const SizedBox(height: 18),
              const Divider(),
              const SizedBox(height: 10),
              if (_sharedHighlights.isEmpty)
                const Text(
                  'Your public profile is where you can share your '
                  'highlights, comments and stories that you recommend.\n\n'
                  'Everything is local and private first, so tap on a '
                  'highlight and select share to your profile to explicitly '
                  'share something on your public profile.',
                  style: TextStyle(fontSize: 13.5, height: 1.5),
                )
              else ...[
                Text(
                    'Shared highlights · ${_sharedHighlights.length}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ..._sharedHighlightTiles(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Shared highlights grouped by the story they come from, like the
  /// public page: the story title once, then its shared quotes.
  List<Widget> _sharedHighlightTiles() {
    final byArticle = <String, List<Share>>{};
    for (final share in _sharedHighlights) {
      byArticle
          .putIfAbsent(share.articleTitle ?? 'Unknown story', () => [])
          .add(share);
    }
    return [
      for (final entry in byArticle.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(entry.key,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
        for (final share in entry.value)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.only(left: 10),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(width: 2.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(share.highlightText ?? '',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, height: 1.4)),
                if ((share.highlightComment ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(share.highlightComment!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontStyle: FontStyle.italic)),
                  ),
              ],
            ),
          ),
      ],
    ];
  }

  Widget _editor() {
    final initial =
        _name.text.trim().isEmpty ? '?' : _name.text.trim()[0].toUpperCase();
    final username = _address?.split('@').first ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(width: 1.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Welcome to your profile. It\'s live at '
                  'einkreader.app/$username. Everything below is tappable — '
                  'fill in what you like.',
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: GestureDetector(
                  onTap: _pickAvatar,
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: Colors.black,
                    foregroundImage:
                        _picture.isEmpty ? null : NetworkImage(_picture),
                    child: _uploading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : (_picture.isEmpty
                            ? Text(initial,
                                style: const TextStyle(
                                    fontSize: 34, color: Colors.white))
                            : null),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text('Tap the avatar to change it',
                    style: TextStyle(
                        fontSize: 12, fontStyle: FontStyle.italic)),
              ),
              if (_address != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(_address!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace')),
                      const SizedBox(height: 4),
                      Text(
                        _addressPending
                            ? 'Registering when back online — this will be '
                                'your address to be tagged and followed'
                            : 'Share this address so people can tag you and '
                                'subscribe to your highlights',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              TextField(
                controller: _name,
                onChanged: (_) => _dirty = true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _about,
                maxLines: 3,
                minLines: 2,
                onChanged: (_) => _dirty = true,
                decoration: const InputDecoration(
                    labelText: 'Short bio',
                    hintText: 'Add a short bio…',
                    alignLabelWithHint: true),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _links,
                maxLines: 3,
                minLines: 2,
                autocorrect: false,
                onChanged: (_) => _dirty = true,
                decoration: const InputDecoration(
                    labelText: 'Social links (one per line)',
                    hintText: 'Add your links…',
                    alignLabelWithHint: true),
              ),
              const SizedBox(height: 22),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Shared highlights',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text(
                'While reading, tap any highlight and choose "Share…" — it '
                'appears on your public page and in the Shared tab.',
                style: TextStyle(
                    fontSize: 12.5,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
              const SizedBox(height: 24),
              const Text(
                'Changes save automatically and publish when you leave this '
                'screen.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
