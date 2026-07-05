import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models.dart';

/// Unobtrusive bar at the bottom of the home screen: when the clipboard holds
/// a URL on launch/resume, offers to save it to read later. Dismissing (or
/// saving) remembers the URL so the same one never prompts again; anything
/// already in the library doesn't prompt either.
class ClipboardLinkPrompt extends StatefulWidget {
  /// Called with the queued article after a save, so the host can refresh
  /// the feed and start the download.
  final void Function(Article saved) onSaved;

  const ClipboardLinkPrompt({super.key, required this.onSaved});

  /// Preference key remembering the last URL prompted for (saved or
  /// dismissed), so it isn't offered twice.
  static const handledUrlPref = 'clipboard_prompt_handled_url';

  @override
  State<ClipboardLinkPrompt> createState() => _ClipboardLinkPromptState();
}

class _ClipboardLinkPromptState extends State<ClipboardLinkPrompt>
    with WidgetsBindingObserver {
  String? _url;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Post-frame: on Android 10+ the clipboard is only readable once the
    // window has focus.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    // Only a bare URL counts: copied prose containing links shouldn't nag.
    final uri = Uri.tryParse(text);
    if (text.contains(RegExp(r'\s')) ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(ClipboardLinkPrompt.handledUrlPref) == text) return;
    if (await AppDatabase.instance.findArticleByUrl(text) != null) return;
    if (!mounted) return;
    setState(() => _url = text);
  }

  Future<void> _rememberHandled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ClipboardLinkPrompt.handledUrlPref, _url!);
  }

  Future<void> _save() async {
    final url = _url!;
    await _rememberHandled();
    final saved = await AppDatabase.instance.saveLinkForLater(url: url);
    if (!mounted) return;
    setState(() => _url = null);
    widget.onSaved(saved);
  }

  Future<void> _dismiss() async {
    await _rememberHandled();
    if (!mounted) return;
    setState(() => _url = null);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null) return const SizedBox.shrink();
    final display = url.replaceFirst(RegExp(r'^https?://(www\.)?'), '');
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(width: 1.5)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(left: 14, top: 6, bottom: 6),
          child: Row(
            children: [
              const Icon(Icons.link, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Copied link: $display',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              OutlinedButton(
                onPressed: _save,
                child: const Text('Read later'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close),
                onPressed: _dismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
