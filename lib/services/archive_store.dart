import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'app_log.dart';

/// On-device archive of everything the reader keeps offline, laid out so a year,
/// month or single source can be archived or deleted by moving a folder:
///
/// ```
/// base/YYYY/MM/source-slug/YYYYMMDD-article-slug.md
/// base/YYYY/MM/source-slug/images/hash.ext
/// base/YYYY/MM/favorites/...            (copies kept even if a source goes)
/// base/highlights.md                    (all highlights, time-independent)
/// ```
///
/// In stored Markdown a downloaded image is referenced as `eink-img://relpath`
/// (relative to the base dir); [localFile] resolves that back to a [File]. The
/// `.md` files written to disk instead use portable `images/name` references so
/// a copied folder stays self-contained.
class ArchiveStore {
  ArchiveStore._();
  static final ArchiveStore instance = ArchiveStore._();

  static const scheme = 'eink-img://';
  static const _maxBytes = 200 * 1024;
  static const _userAgent =
      'Mozilla/5.0 (compatible; einkreader/0.1; +https://github.com/xdamman/einkreader)';

  /// Matches a Markdown image: `![alt](url "optional title")`.
  static final _imageMarkdown =
      RegExp(r'!\[([^\]]*)\]\(\s*([^)\s]+)(\s+"[^"]*")?\s*\)');

  http.Client _client = http.Client();
  String? _basePath;

  /// Cached base path for the synchronous [localFile] used by the renderer.
  static String? _staticBase;

  /// Test seam: point the store at a temp dir and a fake HTTP client.
  void debugConfigure({required String basePath, http.Client? client}) {
    _basePath = basePath;
    _staticBase = basePath;
    if (client != null) _client = client;
    Directory(basePath).createSync(recursive: true);
  }

  Future<String> _base() async {
    if (_basePath != null) return _basePath!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'archive'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _basePath = dir.path;
    _staticBase = dir.path;
    return dir.path;
  }

  /// Absolute path to the offline archive directory, for backup/restore.
  Future<String> baseDir() => _base();

  /// Initializes the cached base path so [localFile] works on a cold start.
  Future<void> ensureInitialized() async {
    await _base();
  }

  /// Resolves an `eink-img://<relpath>` reference to a local [File], or null if
  /// it is not a stored image or the base path is not known yet.
  static File? localFile(String url) {
    if (!url.startsWith(scheme) || _staticBase == null) return null;
    return File(p.join(_staticBase!, url.substring(scheme.length)));
  }

  // -------------------------------------------------------------- path helpers

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "YYYY/MM" for an article's date.
  static String monthDir(DateTime date) => '${date.year}/${_two(date.month)}';

  /// "YYYYMMDD" stamp used to prefix article filenames.
  static String dayStamp(DateTime date) =>
      '${date.year}${_two(date.month)}${_two(date.day)}';

  /// A filesystem-safe kebab slug, capped so paths stay reasonable.
  static String slug(String input) {
    final base = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final capped = base.length > 60 ? base.substring(0, 60) : base;
    return capped.replaceAll(RegExp(r'-+$'), '').isEmpty
        ? 'untitled'
        : capped.replaceAll(RegExp(r'-+$'), '');
  }

  /// Relative directory holding a source's content for a given month, e.g.
  /// "2026/06/stratechery".
  static String sourceDir(DateTime date, String sourceTitle) =>
      '${monthDir(date)}/${slug(sourceTitle)}';

  /// The local date an article is filed under (its publish date, else fetch).
  static DateTime articleDate(Article article) =>
      DateTime.fromMillisecondsSinceEpoch(
          article.publishedAt ?? article.createdAt);

  // ------------------------------------------------------------ image storage

  /// Downloads every image referenced in [markdown] into `<relDir>/images`,
  /// returning the Markdown with those images rewritten to `eink-img://`
  /// references. [maxDimension] is the longest screen edge in physical pixels;
  /// images over 200 KB are scaled so their longest side fits within it.
  Future<String> localizeMarkdown(
    String markdown, {
    required String relDir,
    required int maxDimension,
    bool overwrite = false,
  }) async {
    final urls = <String>{
      for (final m in _imageMarkdown.allMatches(markdown))
        if ((m.group(2) ?? '').startsWith('http')) m.group(2)!,
    };
    if (urls.isEmpty) return markdown;

    final mapping = <String, String>{};
    for (final url in urls) {
      final ref = await _storeImage(url,
          relDir: relDir, maxDimension: maxDimension, overwrite: overwrite);
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

  /// Downloads one image into `<relDir>/images`, resizing if needed, and returns
  /// its `eink-img://<relpath>` reference (or null on failure).
  Future<String?> _storeImage(
    String url, {
    required String relDir,
    required int maxDimension,
    bool overwrite = false,
  }) async {
    final base = await _base();
    final imagesRel = '$relDir/images';
    final hash = sha1.convert(url.codeUnits).toString();
    try {
      // Reuse the copy already on disk (whatever extension it was stored
      // with) so a re-sync neither re-downloads nor re-encodes it, unless the
      // caller is reprocessing and wants a possibly-broken file replaced.
      if (!overwrite) {
        final cached = await _findCached(p.join(base, imagesRel), hash);
        if (cached != null) return '$scheme$imagesRel/$cached';
      }
      final response = await _client
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final bytes = response.bodyBytes;
      final resize = bytes.length > _maxBytes;
      // Decoding + re-encoding a large photo takes seconds of pure CPU, so it
      // runs on a background isolate to keep the UI responsive during sync.
      final stored =
          resize ? await Isolate.run(() => _resize(bytes, maxDimension)) : bytes;
      final ext = resize ? 'jpg' : _extensionFor(response, url);
      final name = '$hash.$ext';
      final ref = '$scheme$imagesRel/$name';
      final file = File(p.join(base, imagesRel, name));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(stored, flush: true);
      await AppLogService.instance.debug(
        'Stored image ${bytes.length}B'
        '${stored.length != bytes.length ? ' → ${stored.length}B' : ''} '
        'as $imagesRel/$name',
      );
      return ref;
    } catch (e) {
      await AppLogService.instance.warn('Could not store image <$url>: $e');
      return null;
    }
  }

  /// Filename of an already-stored image for this URL hash (any extension),
  /// or null when it has not been downloaded yet.
  static Future<String?> _findCached(String dirPath, String hash) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      if (name.startsWith('$hash.')) return name;
    }
    return null;
  }

  static String _extensionFor(http.Response response, String url) {
    final type = response.headers['content-type'] ?? '';
    if (type.contains('png')) return 'png';
    if (type.contains('gif')) return 'gif';
    if (type.contains('webp')) return 'webp';
    if (type.contains('jpeg') || type.contains('jpg')) return 'jpg';
    final ext = p.extension(Uri.parse(url).path).replaceFirst('.', '');
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext.toLowerCase())
        ? ext.toLowerCase()
        : 'jpg';
  }

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

  // --------------------------------------------------------- markdown archive

  /// Writes (or overwrites) the `.md` file for [article] under its source's
  /// month folder, with portable relative image references.
  Future<void> writeArticle({
    required Source source,
    required Article article,
    required String markdown,
  }) async {
    final date = articleDate(article);
    await _writeMarkdownFile(
      relDir: sourceDir(date, source.title),
      article: article,
      source: source,
      markdown: markdown,
    );
  }

  /// Copies [article] (and its images) into `YYYY/MM/favorites/`, so a favorited
  /// or highlighted article survives even if its source is later removed.
  Future<void> copyToFavorites({
    required Source source,
    required Article article,
    required String markdown,
  }) async {
    final date = articleDate(article);
    await _writeMarkdownFile(
      relDir: '${monthDir(date)}/favorites',
      article: article,
      source: source,
      markdown: markdown,
      copyImages: true,
    );
  }

  Future<void> _writeMarkdownFile({
    required String relDir,
    required Article article,
    required Source source,
    required String markdown,
    bool copyImages = false,
  }) async {
    final base = await _base();
    final date = articleDate(article);
    final dir = Directory(p.join(base, relDir));
    await dir.create(recursive: true);

    // Rewrite eink-img refs to portable `images/<name>`, optionally copying the
    // image files alongside the archived markdown.
    final imagesDir = Directory(p.join(dir.path, 'images'));
    final body = await _portableImages(markdown,
        copyInto: copyImages ? imagesDir : null);

    final isoDate =
        '${date.year}-${_two(date.month)}-${_two(date.day)}';
    final header = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${_yaml(article.title)}')
      ..writeln('source: ${_yaml(source.title)}')
      ..writeln('author: ${_yaml(article.author ?? '')}')
      ..writeln('url: ${_yaml(article.url ?? '')}')
      ..writeln('date: $isoDate')
      ..writeln('---')
      ..writeln();

    final name = '${dayStamp(date)}-${slug(article.title)}.md';
    await File(p.join(dir.path, name))
        .writeAsString('$header$body\n', flush: true);
  }

  /// Replaces `eink-img://<relpath>` refs with `images/<name>`, and when
  /// [copyInto] is given copies each referenced file there.
  Future<String> _portableImages(String markdown, {Directory? copyInto}) async {
    final base = await _base();
    final out = StringBuffer();
    var index = 0;
    for (final m in _imageMarkdown.allMatches(markdown)) {
      out.write(markdown.substring(index, m.start));
      final alt = m.group(1) ?? '';
      final url = m.group(2) ?? '';
      final title = m.group(3) ?? '';
      if (url.startsWith(scheme)) {
        final rel = url.substring(scheme.length);
        final name = p.basename(rel);
        if (copyInto != null) {
          final src = File(p.join(base, rel));
          if (await src.exists()) {
            await copyInto.create(recursive: true);
            await src.copy(p.join(copyInto.path, name));
          }
        }
        out.write('![$alt](images/$name$title)');
      } else {
        out.write(m.group(0)!);
      }
      index = m.end;
    }
    out.write(markdown.substring(index));
    return out.toString();
  }

  // ------------------------------------------------------------- highlights

  /// Rewrites the single, time-independent `highlights.md` from [highlights]
  /// (newest first), grouped by article.
  Future<void> writeHighlights(List<Highlight> highlights) async {
    final base = await _base();
    final byArticle = <String, List<Highlight>>{};
    for (final h in highlights) {
      byArticle.putIfAbsent(h.articleTitle ?? 'Untitled', () => []).add(h);
    }
    final out = StringBuffer()..writeln('# Highlights\n');
    byArticle.forEach((title, group) {
      out.writeln('## $title\n');
      for (final h in group) {
        for (final line in h.text.split('\n')) {
          out.writeln('> ${line.trim()}');
        }
        out.writeln();
      }
    });
    await File(p.join(base, 'highlights.md'))
        .writeAsString(out.toString(), flush: true);
  }

  static String _yaml(String value) {
    final escaped = value.replaceAll('"', r'\"').replaceAll('\n', ' ');
    return '"$escaped"';
  }
}
