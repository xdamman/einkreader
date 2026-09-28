import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/profile_screen.dart';
import '../services/errors.dart';
import '../services/profile_service.dart';
import '../services/sync_service.dart';

/// Shown above the Inbox's articles: how to fill it (your
/// name@einkreader.app address, or a prompt to create a profile to get
/// one), who may send to it, and emails from new senders waiting to be
/// accepted.
class InboxHeader extends StatefulWidget {
  /// Called after something changed the feed (a request accepted).
  final VoidCallback onChanged;

  /// True when the "Other senders" filter is selected: the header lists
  /// the emails from senders not yet accepted (Accept / Delete) and the
  /// accepted-senders manager, instead of the address line.
  final bool showRequests;

  const InboxHeader(
      {super.key, required this.onChanged, this.showRequests = false});

  @override
  State<InboxHeader> createState() => _InboxHeaderState();
}

class _InboxHeaderState extends State<InboxHeader> {
  final _profile = ProfileService.instance;
  bool _loaded = false;
  String? _address;
  List<String> _senders = const [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _profile.enabled;
    final address = enabled ? await _profile.nip05Address : null;
    final senders = enabled ? await _profile.allowedSenders : const <String>[];
    if (!mounted) return;
    setState(() {
      _address = address;
      _senders = senders;
      _loaded = true;
    });
  }

  Future<void> _openProfile() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
    await _load();
  }

  Future<void> _accept(EmailRequest request) async {
    setState(() => _busy.add(request.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SyncService.instance.acceptEmailRequest(request);
      messenger.showSnackBar(SnackBar(
          content: Text('${request.from} can now send to your Inbox')));
      widget.onChanged();
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'accepting the sender'))));
    } finally {
      if (mounted) setState(() => _busy.remove(request.id));
    }
  }

  Future<void> _delete(EmailRequest request) async {
    setState(() => _busy.add(request.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SyncService.instance.deleteEmailRequest(request);
      widget.onChanged();
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(friendlyError(e, doing: 'deleting the email'))));
    } finally {
      if (mounted) setState(() => _busy.remove(request.id));
    }
  }

  Future<void> _manageSenders() async {
    final senders = [..._senders];
    final controller = TextEditingController();
    final saved = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: const RoundedRectangleBorder(side: BorderSide(width: 1.5)),
          title: const Text('Accepted senders'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Emails from these addresses go straight to your Inbox. '
                  'Anyone else lands as a request you can accept or delete.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                for (final sender in senders)
                  Row(
                    children: [
                      Expanded(child: Text(sender)),
                      IconButton(
                        tooltip: 'Remove $sender',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setDialogState(() => senders.remove(sender)),
                      ),
                    ],
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                            hintText: 'name@example.com', isDense: true),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final value = controller.text.trim().toLowerCase();
                        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                .hasMatch(value) ||
                            senders.contains(value)) {
                          return;
                        }
                        setDialogState(() => senders.add(value));
                        controller.clear();
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, senders),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final synced = await _profile.setAllowedSenders(saved);
    if (!synced) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Saved — it will reach the server once you are '
              'back online')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final address = _address;
    final requests = SyncService.instance.emailRequests;
    return Container(
      width: double.infinity,
      decoration:
          const BoxDecoration(border: Border(bottom: BorderSide(width: 1))),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (address == null) ...[
            const Text(
              'Set up your profile to create an email address where you '
              'can receive content to read.',
              style: TextStyle(fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(width: 1.5)),
              onPressed: _openProfile,
              child: const Text('Create an einkreader profile'),
            ),
          ] else if (!widget.showRequests) ...[
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Send any link you want to read later to ',
                    style: TextStyle(fontSize: 15)),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$address copied')));
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(address,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      const Icon(Icons.copy, size: 15),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (widget.showRequests) ...[
            const Text(
              'Emails from people you haven\'t accepted yet. Accept a sender '
              'to receive what they send straight in your Inbox.',
              style: TextStyle(fontSize: 14, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _manageSenders,
                child: Text(_senders.isEmpty
                    ? 'Manage accepted senders'
                    : 'Manage accepted senders (${_senders.length})'),
              ),
            ),
          ],
          for (final request in widget.showRequests ? requests : const <EmailRequest>[]) ...[
            const Divider(height: 16),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: request.from,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const TextSpan(text: ' wants to send you '),
                TextSpan(
                    text: '“${request.subject}”',
                    style: const TextStyle(fontStyle: FontStyle.italic)),
              ]),
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
            if (request.url != null)
              Text(request.url!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(width: 1.5)),
                  onPressed: _busy.contains(request.id)
                      ? null
                      : () => _accept(request),
                  child: const Text('Accept sender'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy.contains(request.id)
                      ? null
                      : () => _delete(request),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
