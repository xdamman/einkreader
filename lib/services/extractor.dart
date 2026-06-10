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

  /// Converts an HTML fragment (e.g. content:encoded from a feed) to Markdown.
  static String convertHtmlToMarkdown(String fragment) {
    final markdown = html2md.convert(fragment, styleOptions: {
      'headingStyle': 'atx',
      'codeBlockStyle': 'fenced',
      'emDelimiter': '*',
    });
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
    return bestScore > 250 ? best : null;
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
