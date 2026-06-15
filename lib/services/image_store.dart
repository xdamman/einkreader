import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// Downloads article images to local storage so they can be viewed offline,
/// shrinking anything larger than [_maxBytes] down to the device's longest
/// screen edge.
///
/// In the stored Markdown a downloaded image is referenced as
/// `eink-img://<filename>`; [localFile] resolves that back to a [File] for
/// rendering. Images that fail to download keep their original http(s) URL so
/// the reader can still try to load them online.
class ImageStore {
  ImageStore._();
  static final ImageStore instance = ImageStore._();

  static const scheme = 'eink-img://';
  static const _maxBytes = 200 * 1024;
  static const _userAgent =
      'Mozilla/5.0 (compatible; einkreader/0.1; +https://github.com/xdamman/einkreader)';

  /// Absolute path of the images directory, cached after the first init so the
  /// synchronous renderer can resolve `eink-img://` URLs.
  static String? _dirPath;

  /// Matches a Markdown image: `![alt](url "optional title")`.
  static final _imageMarkdown =
      RegExp(r'!\[([^\]]*)\]\(\s*([^)\s]+)(\s+"[^"]*")?\s*\)');

  /// Creates (once) and returns the on-device images directory.
  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'images'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _dirPath = dir.path;
    return dir;
  }

  /// Initializes the cached directory path so [localFile] works on a cold
  /// start (before any sync has run). Call once at app launch.
  Future<void> ensureInitialized() async {
    if (_dirPath == null) await _dir();
  }

  /// Resolves an `eink-img://name` reference to a local [File], or null if the
  /// reference is not a stored image or the directory is not known yet.
  static File? localFile(String url) {
    if (!url.startsWith(scheme) || _dirPath == null) return null;
    return File(p.join(_dirPath!, url.substring(scheme.length)));
  }

  /// Downloads every image referenced in [markdown], storing each one offline,
  /// and returns the Markdown with downloaded images rewritten to
  /// `eink-img://` references. [maxDimension] is the longest screen edge in
  /// physical pixels; images over 200 KB are scaled so their longest side
  /// fits within it.
  Future<String> localizeMarkdown(
    String markdown, {
    required int maxDimension,
  }) async {
    final urls = <String>{
      for (final m in _imageMarkdown.allMatches(markdown))
        if ((m.group(2) ?? '').startsWith('http')) m.group(2)!,
    };
    if (urls.isEmpty) return markdown;

    final mapping = <String, String>{};
    for (final url in urls) {
      final ref = await _store(url, maxDimension: maxDimension);
      if (ref != null) mapping[url] = ref;
    }
    if (mapping.isEmpty) return markdown;

    return markdown.replaceAllMapped(_imageMarkdown, (m) {
      final alt = m.group(1) ?? '';
      final url = m.group(2) ?? '';
      final title = m.group(3) ?? '';
      final ref = mapping[url];
      return ref == null ? m.group(0)! : '![$alt]($ref$title)';
    });
  }

  /// Downloads a single image, resizing if needed, and returns its
  /// `eink-img://` reference (or null on failure / unsupported content).
  Future<String?> _store(String url, {required int maxDimension}) async {
    final name = sha1.convert(url.codeUnits).toString();
    final dir = await _dir();
    final file = File(p.join(dir.path, name));
    if (await file.exists()) return '$scheme$name';

    try {
      final response = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final bytes = response.bodyBytes;
      final stored = bytes.length > _maxBytes
          ? _resize(bytes, maxDimension)
          : bytes;
      await file.writeAsBytes(stored, flush: true);
      await AppLogService.instance.debug(
        'Stored image ${bytes.length}B'
        '${stored.length != bytes.length ? ' → ${stored.length}B' : ''} '
        '<$url>',
      );
      return '$scheme$name';
    } catch (e) {
      await AppLogService.instance.warn('Could not store image <$url>: $e');
      return null;
    }
  }

  /// Scales [bytes] so its longest side is at most [maxDimension] and
  /// re-encodes it as JPEG. Returns the original bytes if decoding fails.
  static Uint8List _resize(Uint8List bytes, int maxDimension) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longest > maxDimension
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxDimension : null,
            height: decoded.height > decoded.width ? maxDimension : null,
          )
        : decoded;
    return img.encodeJpg(resized, quality: 80);
  }
}
