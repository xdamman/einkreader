import 'dart:ui';

import 'package:einkreader/services/suggested_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the reader's own region comes first, pre-selected", () {
    final fr = regionsFor(const Locale('fr', 'BE'));
    expect(fr.first.name, 'Français');
    expect(fr[1], everywhere);
    final picked = preselectedFor(const Locale('fr', 'BE'));
    expect(picked, containsAll(fr.first.feeds.map((f) => f.url)));
    expect(picked, contains('https://aeon.co/feed.rss'));
  });

  test('a country matches even in English', () {
    expect(regionsFor(const Locale('en', 'ZA')).first.name, 'Africa');
    expect(regionsFor(const Locale('en', 'IN')).first.name, 'South Asia');
  });

  test('no match: everywhere-reads first, every region still offered', () {
    final list = regionsFor(const Locale('nl', 'NL'));
    expect(list.first, everywhere);
    expect(list.length, regions.length + 1);
    expect(preselectedFor(const Locale('nl', 'NL')), hasLength(3));
  });

  test('every feed is https and listed once', () {
    final urls = [
      for (final r in [everywhere, ...regions]) ...r.feeds.map((f) => f.url)
    ];
    expect(urls, everyElement(startsWith('https://')));
    expect(urls.toSet(), hasLength(urls.length));
  });
}
