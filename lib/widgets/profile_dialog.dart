import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../services/profile_service.dart';

/// The profile modal behind the avatar icon. Deliberately short: creating a
/// profile asks only for a name; the editor then invites tapping the avatar
/// to change it, adding a bio and social links. The underlying identity
/// (keys, relays) is an implementation detail kept out of view.
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
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _links = TextEditingController();
  String _picture = '';
  bool _saving = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _links.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await _profileService.enabled;
    if (enabled) {
      final profile = await _profileService.profile();
      _name.text = profile.name;
      _about.text = profile.about;
      _links.text = profile.links;
      _picture = profile.picture;
    }
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  Future<void> _create() async {
    await _profileService.createIdentity();
    // Persist (and best-effort publish) the name right away; details follow
    // in the editor.
    await _profileService.saveProfile(Profile(name: _name.text.trim()));
    await _load();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _profileService.saveProfile(Profile(
      name: _name.text.trim(),
      about: _about.text.trim(),
      picture: _picture,
      links: _links.text.trim(),
    ));
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile saved')));
  }

  Future<void> _pickAvatar() async {
    if (_uploading) return;
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      // Avatars don't need to be huge; shrink before uploading.
      final resized = await Isolate.run(() => _shrink(bytes));
      final url = await _profileService.uploadAvatar(resized);
      if (!mounted) return;
      setState(() => _picture = url);
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
    return AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: Text(_enabled == true ? 'Your profile' : 'Create a profile'),
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
                child: const Text('Create profile',
                    style: TextStyle(fontWeight: FontWeight.w700))),
          ],
        true => [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
            TextButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save profile')),
          ],
      },
    );
  }

  Widget _optIn() {
    return SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'einkreader is private and local-first: nothing leaves this '
            'device unless you share it. A public profile lets you share '
            'chosen highlights and comments — you pick what to share, '
            'every time.',
            style: TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Your name'),
            onSubmitted: (_) => _create(),
          ),
        ],
      ),
    );
  }

  Widget _editor() {
    final initial =
        _name.text.trim().isEmpty ? '?' : _name.text.trim()[0].toUpperCase();
    return SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: GestureDetector(
                onTap: _pickAvatar,
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Colors.black,
                  foregroundImage:
                      _picture.isEmpty ? null : NetworkImage(_picture),
                  child: _uploading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(initial,
                          style: const TextStyle(
                              fontSize: 30, color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Center(
              child: Text(
                'Tap the avatar to change it',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 16),
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
              controller: _links,
              maxLines: 3,
              minLines: 2,
              autocorrect: false,
              decoration: const InputDecoration(
                  labelText: 'Social links (one per line)',
                  hintText: 'https://…',
                  alignLabelWithHint: true),
            ),
          ],
        ),
      ),
    );
  }
}
