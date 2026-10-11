import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:intl/intl.dart';

/// What the reader sees of a post they want to quote: enough to decide
/// whether X allows a native quote, and to draw a screenshot of it when it
/// doesn't.
class QuotedTweet {
  final String id;

  /// Display name, e.g. "Patrick Collison" (or "@patrickc" when unknown).
  final String? authorName;

  /// Handle without the @, e.g. "patrickc".
  final String? username;
  final String text;
  final DateTime? createdAt;

  const QuotedTweet({
    required this.id,
    this.authorName,
    this.username,
    required this.text,
    this.createdAt,
  });

  String get url => 'https://x.com/${username ?? 'i'}/status/$id';

  /// X's API only lets an app quote (or reply to) posts written by the
  /// connected account or that mention it. Checking first avoids a refused
  /// post: anything else goes out as a screenshot instead.
  bool quotableBy(String? me) {
    if (me == null || me.isEmpty) return true; // Unknown: let X decide.
    final handle = me.toLowerCase();
    if (username?.toLowerCase() == handle) return true;
    return RegExp('@${RegExp.escape(handle)}(?![A-Za-z0-9_])',
            caseSensitive: false)
        .hasMatch(text);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'authorName': authorName,
        'username': username,
        'text': text,
        'createdAt': createdAt?.millisecondsSinceEpoch,
      };

  static QuotedTweet? tryParse(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      final created = m['createdAt'] as int?;
      return QuotedTweet(
        id: m['id'] as String,
        authorName: m['authorName'] as String?,
        username: m['username'] as String?,
        text: (m['text'] as String?) ?? '',
        createdAt: created == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(created),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Draws [tweet] as a PNG card like the one X shows for a post: name,
/// @handle and date, the text, and the post's address at the bottom. Black
/// on white, so it reads the same on any screen.
Future<Uint8List> renderTweetCard(QuotedTweet tweet,
    {double width = 1080}) async {
  const pad = 56.0;
  const ink = Color(0xFF000000);
  const grey = Color(0xFF536471);
  final inner = width - 2 * pad;

  // The app's bundled sans: the card looks the same on every device.
  TextPainter layout(String text, TextStyle style, {int? maxLines}) =>
      TextPainter(
        text: TextSpan(
            text: text,
            style: style.copyWith(fontFamily: 'Atkinson Hyperlegible')),
        textDirection: ui.TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: maxLines == null ? null : '…',
      )..layout(maxWidth: inner);

  final handle = tweet.username != null ? '@${tweet.username}' : null;
  final name = (tweet.authorName?.isNotEmpty ?? false)
      ? tweet.authorName!
      : (handle ?? 'Post on X');
  final meta = [
    if (handle != null && handle != name) handle,
    if (tweet.createdAt != null)
      DateFormat('MMM d, y').format(tweet.createdAt!),
  ].join(' · ');
  // Very long posts are cut so the image stays readable in a timeline.
  final body = tweet.text.trim().length > 1500
      ? '${tweet.text.trim().substring(0, 1500)}…'
      : tweet.text.trim();

  final namePainter = layout(
      name,
      const TextStyle(
          fontSize: 40, fontWeight: FontWeight.w700, color: ink),
      maxLines: 1);
  final metaPainter = meta.isEmpty
      ? null
      : layout(meta, const TextStyle(fontSize: 32, color: grey), maxLines: 1);
  final bodyPainter = layout(
      body, const TextStyle(fontSize: 38, height: 1.35, color: ink),
      maxLines: 45);
  final footerPainter = layout(
      tweet.url.replaceFirst('https://', ''),
      const TextStyle(fontSize: 28, color: grey),
      maxLines: 1);

  var y = pad;
  final positions = <(TextPainter, double)>[];
  void place(TextPainter p, double gapAfter) {
    positions.add((p, y));
    y += p.height + gapAfter;
  }

  place(namePainter, 6);
  if (metaPainter != null) place(metaPainter, 32);
  if (metaPainter == null) y += 26;
  place(bodyPainter, 36);
  place(footerPainter, 0);
  final height = (y + pad).ceilToDouble();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFFFFFFF));
  canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(12, 12, width - 24, height - 24),
        const Radius.circular(32)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFCFD9DE),
  );
  for (final (painter, top) in positions) {
    painter.paint(canvas, Offset(pad, top));
  }
  final image = await recorder
      .endRecording()
      .toImage(width.round(), height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
