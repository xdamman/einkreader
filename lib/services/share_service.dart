import 'dart:async';

import 'package:flutter/services.dart';

/// A URL shared into the app, with what surrounded it. Browsers share a page
/// as "Page title\nURL" ([title]) and a text selection as '"selection" URL'
/// ([quote] — saved as a highlight on the queued article).
class SharedLink {
  final String url;
  final String? title;
  final String? quote;

  const SharedLink(this.url, {this.title, this.quote});
}

/// Receives text shared to the app via Android's share sheet (see
/// MainActivity.kt) and emits it raw; the home screen parses it (see [parse])
/// and queues the link to read later — or tells the user when there is none.
class ShareLinkService {
  ShareLinkService._();
  static final ShareLinkService instance = ShareLinkService._();

  static const _channel = MethodChannel('einkreader/share');

  final StreamController<String> texts = StreamController.broadcast();
  bool _initialized = false;

  /// Starts listening for shares pushed into the running app and drains the
  /// share that may have cold-started it. Safe to call more than once.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') {
        _emit(call.arguments as String?);
      }
    });
    try {
      _emit(await _channel.invokeMethod<String>('getInitialSharedText'));
    } on PlatformException {
      // Host side unavailable; nothing was shared.
    } on MissingPluginException {
      // Not running on Android (tests, desktop).
    }
  }

  void _emit(String? text) {
    if (text != null && text.trim().isNotEmpty) texts.add(text);
  }

  static final _urlPattern = RegExp(r'https?://\S+');

  /// Text wrapped in straight or curly quotes — how Chromium browsers share
  /// a selection ("quote" + page URL).
  static final _quoted = RegExp(r'''^["'“‘](.*)["'”’]$''', dotAll: true);

  /// Extracts the first http(s) URL from [text]. Quoted or long surrounding
  /// text is a selection from the page ([SharedLink.quote]); short unquoted
  /// text is a title hint. Returns null when there is no URL.
  static SharedLink? parse(String? text) {
    if (text == null) return null;
    final match = _urlPattern.firstMatch(text);
    if (match == null) return null;
    // Trailing punctuation is usually the sentence's, not the URL's.
    final url = match.group(0)!.replaceFirst(RegExp(r'''[).,;:!?'"”>]+$'''), '');
    if (Uri.tryParse(url)?.host.isEmpty ?? true) return null;
    final rest = text.replaceFirst(match.group(0)!, '').trim();
    if (rest.isEmpty) return SharedLink(url);
    final quoted = _quoted.firstMatch(rest)?.group(1)?.trim();
    if (quoted != null && quoted.isNotEmpty) {
      return SharedLink(url, quote: quoted);
    }
    // Unquoted: a page title is short; anything longer reads as a selection.
    return rest.length > 80
        ? SharedLink(url, quote: rest)
        : SharedLink(url, title: rest);
  }
}
