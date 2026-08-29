import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;

/// Extracts the readable article from a full HTML page and converts it to
/// Markdown (a lightweight, on-device equivalent of pandoc / readability).
class ArticleExtractor {
  static const _strip = [
    'script', 'style', 'noscript', 'iframe', 'form', 'nav', 'header',
    'footer', 'aside', 'button', 'svg', 'canvas', 'video', 'audio',
  ];

  static final _negative = RegExp(
      r'comment|share|social|sidebar|footer|header|nav|menu|promo|related|'
      r'subscribe|newsletter|advert|banner|cookie|popup',
      caseSensitive: false);

  /// Converts a full HTML page to article Markdown.
  /// Returns null when no plausible article content is found.
  static String? extract(String htmlString, {String? baseUrl}) {
    final doc = html_parser.parse(htmlString);
    final body = doc.body;
    if (body == null) return null;

    for (final tag in _strip) {
      for (final el in doc.querySelectorAll(tag)) {
        el.remove();
      }
    }

    final candidate = _bestCandidate(body) ?? body;
    _resolveUrls(candidate, baseUrl);
    final markdown = convertHtmlToMarkdown(candidate.outerHtml);
    return markdown.trim().length < 140 ? null : markdown;
  }

  /// A linked image `[ ![alt](src) ](href)`, which html2md emits (often split
  /// across lines) for an `<img>` wrapped in an `<a>`. Whitespace and the URLs
  /// may contain newlines, so this spans lines.
  static final _linkedImage =
      RegExp(r'\[\s*(!\[[^\]]*\]\([^)]*\))\s*\]\([^)]*\)');

  /// Class names that mark screen-reader-only content ("Copy link to
  /// heading" and friends): visually hidden on the web, but html2md knows
  /// nothing of CSS, so without this pass the labels leak into the text.
  static final _hiddenClass = RegExp(
      r'(^|\s)(sr-only|sr_only|visually-hidden|visuallyhidden|'
      r'screen-reader-text|screen-reader-only|screenreader)(\s|$)',
      caseSensitive: false);

  static final _hiddenStyle = RegExp(
      r'display\s*:\s*none|visibility\s*:\s*hidden',
      caseSensitive: false);

  /// Removes elements a browser would never paint: [hidden], hidden inline
  /// styles, and screen-reader-only classes. Anchor links left empty by
  /// that (a heading's self-link icon) are dropped too.
  static String _stripInvisible(String fragment) {
    final frag = html_parser.parseFragment(fragment);
    // Feed fragments arrive here without the page-level tag strip; a
    // <style> block in content:encoded would otherwise render as CSS text.
    for (final tag in _strip) {
      for (final el in frag.querySelectorAll(tag)) {
        el.remove();
      }
    }
    for (final el in frag.querySelectorAll('*')) {
      final classes = el.attributes['class'] ?? '';
      final style = el.attributes['style'] ?? '';
      if (el.attributes.containsKey('hidden') ||
          _hiddenClass.hasMatch(classes) ||
          _hiddenStyle.hasMatch(style)) {
        el.remove();
      }
    }
    for (final a in frag.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (href.startsWith('#') && a.text.trim().isEmpty) a.remove();
    }
    // Avatars, icons and tracking pixels are byline chrome, not article
    // content — and they render as awkward blocks on e-ink.
    for (final img in frag.querySelectorAll('img')) {
      final w = int.tryParse(img.attributes['width'] ?? '');
      final h = int.tryParse(img.attributes['height'] ?? '');
      final classes = img.attributes['class'] ?? '';
      final alt = img.attributes['alt'] ?? '';
      final src = img.attributes['src'] ?? '';
      // CDN resize params like w_36,h_36 reveal the display size even when
      // the attributes are missing (Substack, Cloudinary).
      final cdn = RegExp(r'[/,]w_(\d+),h_(\d+)[/,]').firstMatch(src);
      final cdnSide = cdn == null
          ? null
          : [int.parse(cdn.group(1)!), int.parse(cdn.group(2)!)]
              .reduce((a, b) => a > b ? a : b);
      final tiny = (w != null && w <= 64) ||
          (h != null && h <= 64) ||
          (cdnSide != null && cdnSide <= 64);
      final avatarish = RegExp('avatar', caseSensitive: false)
              .hasMatch('$classes $alt') ||
          src.contains('avatar');
      if (tiny || avatarish) img.remove();
    }
    return frag.outerHtml;
  }

  /// Converts an HTML fragment (e.g. content:encoded from a feed) to Markdown.
  static String convertHtmlToMarkdown(String fragment) {
    var markdown = html2md.convert(_stripInvisible(fragment), styleOptions: {
      'headingStyle': 'atx',
      'codeBlockStyle': 'fenced',
      'emDelimiter': '*',
    });
    // Reduce a linked image to just the image, otherwise the wrapping link's
    // `](href)` lands on its own line and renders as a literal text fragment.
    markdown = markdown.replaceAllMapped(_linkedImage, (m) => m.group(1)!);
    // Collapse runs of blank lines left behind by stripped elements.
    return markdown.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Reads the page title (og:title preferred) from an HTML page.
  static String? extractTitle(String htmlString) {
    final doc = html_parser.parse(htmlString);
    final og = doc
        .querySelector('meta[property="og:title"]')
        ?.attributes['content']
        ?.trim();
    if (og != null && og.isNotEmpty) return og;
    final title = doc.querySelector('title')?.text.trim();
    return (title == null || title.isEmpty) ? null : title;
  }

  /// Picks the element most likely to contain the article body: the
  /// `<article>`/`<main>` element, or the block with the most paragraph text.
  static dom.Element? _bestCandidate(dom.Element body) {
    final semantic = body.querySelector('article') ?? body.querySelector('main');
    if (semantic != null && _paragraphLength(semantic) > 250) return semantic;

    dom.Element? best;
    var bestScore = 0;
    for (final el in body.querySelectorAll('div, section, article, main')) {
      final idClass = '${el.id} ${el.className}';
      if (_negative.hasMatch(idClass)) continue;
      var score = _paragraphLength(el);
      // Prefer deeper, more specific containers over page-level wrappers.
      if (el.querySelectorAll('p').length > 3) score += 100;
      if (score > bestScore) {
        // Skip ancestors that barely add content over the current best.
        if (best != null && _contains(el, best) && score < bestScore * 1.5) {
          continue;
        }
        best = el;
        bestScore = score;
      }
    }
    if (bestScore > 250) return best;
    // Table-layout era pages (paulgraham.com): no <p> anywhere — the essay
    // is one long text run separated by <br><br> inside nested layout
    // tables. Descend to the deepest element still holding most of the
    // page text; converting from there leaves the layout tables (which
    // html2md would garble into raw-HTML table cells) behind.
    return _deepTextCandidate(body);
  }

  /// The deepest element containing ≥80% of the page's text, or null when
  /// the text is spread out (then the caller keeps its body fallback).
  static dom.Element? _deepTextCandidate(dom.Element body) {
    if (body.text.trim().length < 500) return null;
    var current = body;
    while (true) {
      dom.Element? dominant;
      final threshold = current.text.trim().length * 0.8;
      for (final child in current.children) {
        if (_negative.hasMatch('${child.id} ${child.className}')) continue;
        if (child.text.trim().length >= threshold) {
          dominant = child;
          break;
        }
      }
      if (dominant == null) return identical(current, body) ? null : current;
      current = dominant;
    }
  }

  static int _paragraphLength(dom.Element el) {
    var total = 0;
    for (final p in el.querySelectorAll('p')) {
      final len = p.text.trim().length;
      if (len > 40) total += len;
    }
    return total;
  }

  static bool _contains(dom.Element ancestor, dom.Element node) {
    dom.Node? current = node;
    while (current != null) {
      if (identical(current, ancestor)) return true;
      current = current.parent;
    }
    return false;
  }

  /// Makes relative img/anchor URLs absolute so they work outside the page.
  static void _resolveUrls(dom.Element root, String? baseUrl) {
    if (baseUrl == null) return;
    final base = Uri.tryParse(baseUrl);
    if (base == null) return;
    for (final entry in const [('img', 'src'), ('a', 'href')]) {
      for (final el in root.querySelectorAll(entry.$1)) {
        final value = el.attributes[entry.$2];
        if (value == null || value.startsWith('data:')) continue;
        final resolved = base.resolve(value).toString();
        el.attributes[entry.$2] = resolved;
      }
    }
  }
}
