import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models.dart';

/// People you share reads with — stored on this device only, never uploaded.
/// Each contact carries the channel they prefer (email now; Nostr DM soon).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _db = AppDatabase.instance;
  List<Contact> _contacts = [];
  final _name = TextEditingController();
  final _address = TextEditingController();
  String _channel = 'email';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final contacts = await _db.getContacts();
    if (!mounted) return;
    setState(() => _contacts = contacts);
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    final address = _address.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name is required');
      return;
    }
    final valid = _channel == 'email'
        ? RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(address)
        : address.startsWith('npub1');
    if (!valid) {
      setState(() => _error = _channel == 'email'
          ? 'Enter a valid email address'
          : 'Enter an npub1… key');
      return;
    }
    await _db.insertContact(Contact(
      name: name,
      channel: _channel,
      address: address,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _name.clear();
    _address.clear();
    setState(() => _error = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'People you share reads with. Stored on this device only — '
                  'never uploaded.',
                  style: TextStyle(fontSize: 13.5),
                ),
                const SizedBox(height: 14),
                for (final contact in _contacts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: Colors.black,
                      child: Text(
                          contact.name.isEmpty
                              ? '?'
                              : contact.name[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white)),
                    ),
                    title: Text(contact.name),
                    subtitle: Text(
                        '${contact.address} · '
                        '${contact.channel == 'email' ? '✉ email' : '🔑 nostr dm'}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: IconButton(
                      tooltip: 'Remove contact',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await _db.deleteContact(contact.id!);
                        _load();
                      },
                    ),
                  ),
                const Divider(height: 30),
                const Text('Add contact',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('Reach them by:',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 10),
                    ChoiceChip(
                      label: const Text('✉ email'),
                      selected: _channel == 'email',
                      onSelected: (_) => setState(() => _channel = 'email'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('🔑 nostr'),
                      selected: _channel == 'nostr',
                      onSelected: (_) => setState(() => _channel = 'nostr'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _address,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText:
                        _channel == 'email' ? 'Email address' : 'npub',
                    hintText: _channel == 'email'
                        ? 'marc@example.com'
                        : 'npub1…',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _add(),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                    onPressed: _add, child: const Text('Add contact')),
                if (_channel == 'nostr')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Nostr DMs are coming soon — the contact is saved and '
                      'lights up in the composer when they ship.',
                      style:
                          TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
