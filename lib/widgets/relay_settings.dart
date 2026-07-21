import 'package:flutter/material.dart';

import '../services/nostr_service.dart';

/// Settings section for the Nostr relay list: explains what relays are,
/// shows each relay's connection status, and lets the user add/remove them.
class RelaySettings extends StatefulWidget {
  /// Test seam: replaces the live WebSocket handshake check.
  final Future<bool> Function(String relay)? checker;

  const RelaySettings({super.key, this.checker});

  @override
  State<RelaySettings> createState() => _RelaySettingsState();
}

class _RelaySettingsState extends State<RelaySettings> {
  List<String> _relays = [];

  /// null = still checking.
  final Map<String, bool?> _status = {};
  final _addController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final relays = await NostrService.relays();
    if (!mounted) return;
    setState(() {
      _relays = [...relays];
      for (final relay in relays) {
        _status.putIfAbsent(relay, () => null);
      }
    });
    for (final relay in relays) {
      _check(relay);
    }
  }

  Future<void> _check(String relay) async {
    final ok = await (widget.checker ?? NostrService.checkRelay)(relay);
    if (!mounted) return;
    setState(() => _status[relay] = ok);
  }

  Future<void> _add() async {
    final url = _addController.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('wss://') && !url.startsWith('ws://')) {
      setState(() => _error = 'A relay address starts with wss://');
      return;
    }
    if (_relays.contains(url)) {
      setState(() => _error = 'Already in the list');
      return;
    }
    setState(() {
      _error = null;
      _relays.add(url);
      _status[url] = null;
      _addController.clear();
    });
    await NostrService.saveRelays(_relays);
    _check(url);
  }

  Future<void> _remove(String relay) async {
    setState(() => _relays.remove(relay));
    await NostrService.saveRelays(_relays);
    if (_relays.isEmpty) {
      // An empty list falls back to the defaults; show them again.
      await _load();
    }
  }

  Widget _statusIcon(String relay) => switch (_status[relay]) {
        null => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        true => const Icon(Icons.check_circle_outline, size: 20),
        false => const Icon(Icons.cloud_off_outlined, size: 20),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Relays are small independent servers that carry your public '
          'profile and anything you choose to share (and they serve your '
          'Nostr bookmarks, if configured). Nothing is sent to them until '
          'you share. Several relays give redundancy: if one is down, the '
          'others still deliver. Removing every relay restores the '
          'defaults.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 8),
        for (final relay in _relays)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: _statusIcon(relay),
            title: Text(relay,
                style:
                    const TextStyle(fontSize: 14, fontFamily: 'monospace')),
            subtitle: _status[relay] == false
                ? const Text('Not reachable right now',
                    style: TextStyle(fontSize: 12))
                : null,
            trailing: IconButton(
              tooltip: 'Remove relay',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _remove(relay),
            ),
          ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _addController,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Add relay',
                  hintText: 'wss://relay.example.com',
                  isDense: true,
                  errorText: _error,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _add, child: const Text('Add')),
          ],
        ),
      ],
    );
  }
}
