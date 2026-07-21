import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/profile_service.dart';

/// The profile modal behind the avatar icon. First visit offers the opt-in
/// (private and local-first by default; a profile only makes sharing
/// possible); once created, it edits name / bio / avatar / links and exposes
/// the keys for backup.
class ProfileDialog extends StatefulWidget {
  const ProfileDialog({super.key});

  /// Opens the modal.
  static Future<void> show(BuildContext context) => showDialog(
      context: context, builder: (context) => const ProfileDialog());

  @override
  State<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<ProfileDialog> {
  final _profileService = ProfileService.instance;
  bool? _enabled; // null while loading
  String _npub = '';
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _picture = TextEditingController();
  final _links = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _picture.dispose();
    _links.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await _profileService.enabled;
    if (enabled) {
      final profile = await _profileService.profile();
      _name.text = profile.name;
      _about.text = profile.about;
      _picture.text = profile.picture;
      _links.text = profile.links;
      _npub = await _profileService.npub;
    }
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  Future<void> _create() async {
    await _profileService.createIdentity();
    await _load();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final accepted = await _profileService.saveProfile(Profile(
      name: _name.text.trim(),
      about: _about.text.trim(),
      picture: _picture.text.trim(),
      links: _links.text.trim(),
    ));
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(accepted > 0
            ? 'Profile saved and published'
            : 'Profile saved — publish queued in the outbox')));
  }

  Future<void> _copyNsec() async {
    await Clipboard.setData(ClipboardData(text: await _profileService.nsec));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Secret key copied — store it somewhere safe')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: Text(_enabled == true ? 'Your profile' : 'Public profile'),
      content: switch (_enabled) {
        null => const SizedBox(
            width: 60, height: 60, child: Center(child: Text('…'))),
        false => _optIn(),
        true => _editor(),
      },
      actions: switch (_enabled) {
        null => const [],
        false => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Not now')),
            TextButton(
                onPressed: _create,
                child: const Text('Create public profile',
                    style: TextStyle(fontWeight: FontWeight.w700))),
          ],
        true => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
            TextButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save & publish')),
          ],
      },
    );
  }

  Widget _optIn() {
    return const SizedBox(
      width: 440,
      child: Text(
        'einkreader is private and local-first: what you read, highlight '
        'and note stays on this device.\n\n'
        'If you like, you can create a public profile to share chosen '
        'highlights, favorites and comments. Nothing is ever shared '
        'automatically — you stay in control and pick what to share, '
        'every time.\n\n'
        'The profile is a key pair generated on this device (a Nostr '
        'identity) — no account, no email, no server of ours.',
        style: TextStyle(fontSize: 14, height: 1.4),
      ),
    );
  }

  Widget _editor() {
    return SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _about,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Short bio', alignLabelWithHint: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _picture,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Avatar image URL',
                  hintText: 'https://…/me.jpg'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _links,
              maxLines: 3,
              minLines: 2,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Social links (one per line)',
                  hintText: 'https://…',
                  alignLabelWithHint: true),
            ),
            const SizedBox(height: 16),
            Text('Public id: $_npub',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.key_outlined),
              label: const Text('Copy secret key (nsec)'),
              onPressed: _copyNsec,
            ),
            const SizedBox(height: 4),
            const Text(
              'Your secret key stays on this device and is included in '
              'Android\'s standard app backup, so restoring einkreader on '
              'a new device (same Google account) restores your profile. '
              'Copy it above for an extra safety net.',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}
