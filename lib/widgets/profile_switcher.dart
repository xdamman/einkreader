import 'package:flutter/material.dart';

import '../screens/profile_screen.dart';
import '../services/profile_service.dart';

/// Anchored menu (long-press on the profile icon, or from Settings) to
/// switch between profile slots or add one. The last used profile is
/// remembered by ProfileService.
Future<void> showProfileSwitcherMenu(BuildContext context) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final origin = box == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  final summaries = await ProfileService.instance.profileSummaries();
  if (!context.mounted) return;
  final choice = await showMenu<String>(
    context: context,
    shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
    position: RelativeRect.fromRect(
      origin & (box?.size ?? Size.zero),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final summary in summaries)
        PopupMenuItem(
          value: summary.id,
          child: Text(
            '${summary.active ? '✓ ' : ''}'
            '${summary.name.isNotEmpty ? summary.name : (summary.hasIdentity ? 'Unnamed profile' : 'Empty profile')}',
            style: TextStyle(
                fontWeight:
                    summary.active ? FontWeight.w700 : FontWeight.w400),
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: '__add__', child: Text('Add profile…')),
    ],
  );
  if (choice == null || !context.mounted) return;
  if (choice == '__add__') {
    await showAddProfileDialog(context);
  } else {
    await ProfileService.instance.switchTo(choice);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile switched')));
  }
}

/// "Add profile": create a fresh one, or — advanced, behind a plain link —
/// import an existing identity from its nsec.
Future<void> showAddProfileDialog(BuildContext context) async {
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => const _AddProfileDialog(),
  );
  if (action == null || !context.mounted) return;
  // Either path lands on the profile screen: create shows the opt-in for
  // the fresh slot; import shows the imported identity.
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
}

class _AddProfileDialog extends StatefulWidget {
  const _AddProfileDialog();

  @override
  State<_AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<_AddProfileDialog> {
  final _nsec = TextEditingController();
  bool _importing = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nsec.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    await ProfileService.instance.addProfileSlot();
    if (!mounted) return;
    Navigator.of(context).pop('create');
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      await ProfileService.instance.importNsec(_nsec.text.trim());
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop('import');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
      title: const Text('Add a profile'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_importing) ...[
              const Text(
                'A separate identity with its own name, address and '
                'shared highlights.',
                style: TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _busy ? null : _create,
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(width: 2)),
                child: const Text('Create a new profile',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              // Advanced, deliberately quiet: a plain link, not a button.
              Center(
                child: TextButton(
                  onPressed: () => setState(() => _importing = true),
                  child: const Text('Import an existing profile',
                      style: TextStyle(
                          fontSize: 13,
                          decoration: TextDecoration.underline)),
                ),
              ),
            ] else ...[
              const Text(
                'Paste the secret key (nsec1…) of the profile to import. '
                'It never leaves this device.',
                style: TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nsec,
                autofocus: true,
                autocorrect: false,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'nsec',
                  hintText: 'nsec1…',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _import(),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _import,
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(width: 2)),
                child: Text(_busy ? 'Importing…' : 'Import profile',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
      ],
    );
  }
}
