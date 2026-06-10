import 'package:xml/xml.dart';

/// A single entry parsed from an RSS or Atom feed.
class FeedItem {
  final String guid;
  final String title;
  final String? link;
  final String? author;
  final DateTime? published;
  final String? summaryHtml;

  /// Full content if the feed includes it (content:encoded / atom content).
  final String? contentHtml;

  const FeedItem({
    required this.guid,
    required this.title,
    this.link,
    this.author,
    this.published,
    this.summaryHtml,
    this.contentHtml,
  });
}

class ParsedFeed {
  final String title;
  final List<FeedItem> items;
  const ParsedFeed({required this.title, required this.items});
}

/// Minimal, dependency-light RSS 2.0 / Atom parser.
class FeedParser {
  static ParsedFeed parse(String xmlString) {
    final doc = XmlDocument.parse(xmlString);
    final root = doc.rootElement;
    if (root.name.local == 'feed') return _parseAtom(root);
    final channel = root.findElements('channel').firstOrNull ??
        root.findAllElements('channel').firstOrNull;
    if (channel == null) {
      throw const FormatException('Not a recognizable RSS or Atom feed');
    }
    return _parseRss(channel);
  }

  static ParsedFeed _parseRss(XmlElement channel) {
    final feedTitle = _text(channel, 'title') ?? 'Untitled feed';
    final items = <FeedItem>[];
    for (final item in channel.findElements('item')) {
      final link = _text(item, 'link');
      final guid = _text(item, 'guid') ?? link;
      if (guid == null) continue;
      final content = _textNs(item, 'encoded', 'content') ??
          _textNs(item, 'encoded',
              'http://purl.org/rss/1.0/modules/content/');
      items.add(FeedItem(
        guid: guid,
        title: _text(item, 'title') ?? link ?? 'Untitled',
        link: link,
        author: _text(item, 'author') ?? _textNs(item, 'creator', 'dc'),
        published: _parseDate(_text(item, 'pubDate')),
        summaryHtml: _text(item, 'description'),
        contentHtml: content,
      ));
    }
    return ParsedFeed(title: feedTitle, items: items);
  }

  static ParsedFeed _parseAtom(XmlElement feed) {
    final feedTitle = _text(feed, 'title') ?? 'Untitled feed';
    final items = <FeedItem>[];
    for (final entry in feed.findElements('entry')) {
      final id = _text(entry, 'id');
      final link = _atomLink(entry);
      if (id == null && link == null) continue;
      items.add(FeedItem(
        guid: id ?? link!,
        title: _text(entry, 'title') ?? link ?? 'Untitled',
        link: link,
        author: entry
            .findElements('author')
            .firstOrNull
            ?.findElements('name')
            .firstOrNull
            ?.innerText
            .trim(),
        published: _parseDate(
            _text(entry, 'published') ?? _text(entry, 'updated')),
        summaryHtml: _text(entry, 'summary'),
        contentHtml: entry.findElements('content').firstOrNull?.innerText,
      ));
    }
    return ParsedFeed(title: feedTitle, items: items);
  }

  static String? _atomLink(XmlElement entry) {
    String? fallback;
    for (final link in entry.findElements('link')) {
      final href = link.getAttribute('href');
      if (href == null) continue;
      final rel = link.getAttribute('rel');
      if (rel == null || rel == 'alternate') return href;
      fallback ??= href;
    }
    return fallback;
  }

  static String? _text(XmlElement parent, String name) {
    final value = parent.findElements(name).firstOrNull?.innerText.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Finds `<prefix:name>` regardless of how the namespace is bound.
  static String? _textNs(XmlElement parent, String local, String nsHint) {
    for (final child in parent.childElements) {
      if (child.name.local == local &&
          (child.name.prefix == nsHint ||
              (child.name.namespaceUri?.contains(nsHint) ?? false))) {
        final value = child.innerText.trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Parses ISO-8601 (Atom) and RFC-822 (RSS) dates.
  static DateTime? _parseDate(String? raw) {
    if (raw == null) return null;
    final iso = DateTime.tryParse(raw);
    if (iso != null) return iso;
    // RFC 822, e.g. "Tue, 10 Jun 2026 08:30:00 +0200" or "... GMT".
    final m = RegExp(
            r'(\d{1,2})\s+([A-Za-z]{3})\w*\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Z]{1,5})?')
        .firstMatch(raw);
    if (m == null) return null;
    final month = _months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    var date = DateTime.utc(year, month, int.parse(m.group(1)!),
        int.parse(m.group(4)!), int.parse(m.group(5)!),
        int.parse(m.group(6) ?? '0'));
    final zone = m.group(7);
    if (zone != null && RegExp(r'^[+-]\d{4}$').hasMatch(zone)) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final offset = Duration(
          hours: int.parse(zone.substring(1, 3)),
          minutes: int.parse(zone.substring(3, 5)));
      date = date.subtract(offset * sign);
    }
    return date;
  }
}
