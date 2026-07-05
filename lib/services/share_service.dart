import 'dart:async';

import 'package:flutter/services.dart';

/// A URL shared into the app, with any surrounding text as a title hint
/// (browsers often share "Page title\nhttps://…").
class SharedLink {
  final String url;
  final String? title;

  const SharedLink(this.url, {this.title});
}

/// Receives text shared to the app via Android's share sheet (see
/// MainActivity.kt) and emits the links found in it. The home screen listens
/// and queues them to read later.
class ShareLinkService {
  ShareLinkService._();
  static final ShareLinkService instance = ShareLinkService._();

  static const _channel = MethodChannel('einkreader/share');

  final StreamController<SharedLink> links = StreamController.broadcast();
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
    final link = parse(text);
    if (link != null) links.add(link);
  }

  static final _urlPattern = RegExp(r'https?://\S+');

  /// Extracts the first http(s) URL from [text]; the remaining text becomes
  /// the title hint. Returns null when there is no URL.
  static SharedLink? parse(String? text) {
    if (text == null) return null;
    final match = _urlPattern.firstMatch(text);
    if (match == null) return null;
    // Trailing punctuation is usually the sentence's, not the URL's.
    final url = match.group(0)!.replaceFirst(RegExp(r'''[).,;:!?'"”>]+$'''), '');
    if (Uri.tryParse(url)?.host.isEmpty ?? true) return null;
    final title = text.replaceFirst(match.group(0)!, '').trim();
    return SharedLink(url, title: title.isEmpty ? null : title);
  }
}
