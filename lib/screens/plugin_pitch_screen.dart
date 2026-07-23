import 'package:flutter/material.dart';

import '../services/plugin_service.dart';

/// The supporter pitch: what's free forever, what plugins add, and the three
/// durations. Until Google Play billing ships, the button grants free early
/// access so the plugin machinery is fully usable.
class PluginPitchScreen extends StatefulWidget {
  const PluginPitchScreen({super.key});

  @override
  State<PluginPitchScreen> createState() => _PluginPitchScreenState();
}

class _PluginPitchScreenState extends State<PluginPitchScreen> {
  int _selected = 1; // 0 = monthly, 1 = yearly, 2 = five years

  static const _options = [
    (amount: '€10', per: '/ month', save: null),
    (amount: '€50', per: '/ year', save: 'SAVE 58%'),
    (amount: '€100', per: '/ 5 years', save: 'SAVE 83%'),
  ];

  Future<void> _activate() async {
    await PluginService.instance.activateEarlyAccess();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Plugins unlocked — early access is free until Play billing '
            'arrives. Thank you!')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Supporter')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Free forever',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                  'Reading every source, highlights & notes, offline archive, '
                  'your @einkreader.app address & public page, sharing to '
                  'your profile, compose-email, copy link, following anyone.',
                  style: TextStyle(fontSize: 14, height: 1.45),
                ),
                const Divider(height: 32),
                const Text('Supporter unlocks plugins',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                  '@  Twitter — bookmarks in, highlights out\n'
                  '✉  Email — read by email, one-tap sends, page subscribers\n'
                  '♥  and it pays for the servers',
                  style: TextStyle(fontSize: 14, height: 1.6),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    for (var i = 0; i < _options.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _selected = i),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _selected == i
                                  ? Colors.black
                                  : Colors.white,
                              border: Border.all(width: 1.6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              children: [
                                Text(_options[i].amount,
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 17,
                                        color: _selected == i
                                            ? Colors.white
                                            : Colors.black)),
                                Text(_options[i].per,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: _selected == i
                                            ? Colors.white70
                                            : Colors.grey)),
                                if (_options[i].save != null)
                                  Text(_options[i].save!,
                                      style: TextStyle(
                                          fontSize: 9,
                                          letterSpacing: 0.5,
                                          color: _selected == i
                                              ? Colors.white
                                              : Colors.black)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _activate,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(width: 2),
                  ),
                  child: const Text('Start early access — free for now',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Google Play billing is on its way; early access is free '
                  'until then. Cancelling never touches the free tier.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
