import 'dart:ui';

/// A feed offered to new readers who'd rather not start from an empty
/// library. Mostly essays and long reads (good on e-ink), some daily
/// writing so there's always something fresh.
class SuggestedFeed {
  final String title;
  final String url;
  final String description;

  const SuggestedFeed(this.title, this.url, this.description);
}

/// Suggestions from one part of the world. A reader whose device language
/// or country matches sees this region first, its feeds pre-selected.
class SuggestedRegion {
  final String name;
  final Set<String> languages;
  final Set<String> countries;
  final List<SuggestedFeed> feeds;

  const SuggestedRegion(this.name,
      {this.languages = const {},
      this.countries = const {},
      required this.feeds});

  bool matches(Locale locale) =>
      countries.contains(locale.countryCode?.toUpperCase()) ||
      languages.contains(locale.languageCode.toLowerCase());
}

/// Everyone's starting point, pre-selected for every reader.
const everywhere = SuggestedRegion('Ideas & long reads', feeds: [
  SuggestedFeed('Aeon', 'https://aeon.co/feed.rss',
      'Essays on philosophy, science, psychology and culture'),
  SuggestedFeed('The Marginalian', 'https://www.themarginalian.org/feed/',
      'Maria Popova on books, art and how to live'),
  SuggestedFeed('Hacker News', 'https://hnrss.org/frontpage',
      "Today's most discussed links in tech"),
  SuggestedFeed('Noema', 'https://www.noemamag.com/feed/',
      'Long essays on technology, politics and the planet'),
  SuggestedFeed('Psyche', 'https://psyche.co/feed',
      'Guides and essays on living well'),
  SuggestedFeed('Quanta Magazine', 'https://api.quantamagazine.org/feed/',
      'Mathematics, physics and biology, clearly explained'),
  SuggestedFeed('Rest of World', 'https://restofworld.org/feed/latest',
      'How technology changes lives outside the West'),
  SuggestedFeed('New Lines Magazine', 'https://newlinesmag.com/feed/',
      'Reporting and essays from the Middle East and beyond'),
  SuggestedFeed('Longreads', 'https://longreads.com/feed/',
      'The best long-form storytelling, picked by editors'),
  SuggestedFeed('The Public Domain Review',
      'https://publicdomainreview.org/rss.xml',
      'Curious finds from the history of art and ideas'),
  SuggestedFeed('Kottke', 'https://feeds.kottke.org/main',
      'A daily mix of the web, from 1998 and still going'),
]);

/// Regional picks, in the order shown when none matches the reader.
const regions = [
  SuggestedRegion('United Kingdom & Ireland', countries: {'GB', 'IE'},
      feeds: [
        SuggestedFeed('The Guardian Long Read',
            'https://www.theguardian.com/news/series/the-long-read/rss',
            "The Guardian's in-depth features"),
        SuggestedFeed('The Conversation UK',
            'https://theconversation.com/uk/articles.atom',
            'Academics write about their research'),
      ]),
  SuggestedRegion('United States & Canada', countries: {'US', 'CA'},
      feeds: [
        SuggestedFeed('The New Yorker',
            'https://www.newyorker.com/feed/everything',
            'Reporting, criticism, fiction and humor'),
        SuggestedFeed('ProPublica', 'https://feeds.propublica.org/propublica/main',
            'Nonprofit investigative journalism'),
      ]),
  SuggestedRegion('Français', languages: {'fr'}, feeds: [
    SuggestedFeed('Le Monde diplomatique',
        'https://www.monde-diplomatique.fr/recents.xml',
        'Analyses et enquêtes internationales'),
    SuggestedFeed('The Conversation France',
        'https://theconversation.com/fr/articles.atom',
        'Des chercheurs racontent leurs travaux'),
    SuggestedFeed('Usbek & Rica', 'https://usbeketrica.com/fr/rss',
        'Le magazine qui explore le futur'),
    SuggestedFeed('Socialter', 'https://www.socialter.fr/rss',
        'Écologie, société et alternatives'),
  ]),
  SuggestedRegion('Deutsch', languages: {'de'}, feeds: [
    SuggestedFeed('Zeit Online', 'https://newsfeed.zeit.de/index',
        'Nachrichten, Hintergründe und Debatten'),
    SuggestedFeed('netzpolitik.org', 'https://netzpolitik.org/feed/',
        'Digitale Freiheitsrechte und Netzpolitik'),
  ]),
  SuggestedRegion('Español', languages: {'es'}, feeds: [
    SuggestedFeed('El País · Ideas',
        'https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/section/ideas/portada',
        'Ensayos y debates de El País'),
    SuggestedFeed('Jot Down', 'https://www.jotdown.es/feed/',
        'Cultura, entrevistas largas y ensayo'),
    SuggestedFeed('Revista Anfibia', 'https://www.revistaanfibia.com/feed/',
        'Crónicas y ensayos desde América Latina'),
  ]),
  SuggestedRegion('Italiano', languages: {'it'}, feeds: [
    SuggestedFeed('Internazionale',
        'https://www.internazionale.it/sitemaps/rss.xml',
        'Il meglio dei giornali di tutto il mondo'),
  ]),
  SuggestedRegion('Português', languages: {'pt'}, feeds: [
    SuggestedFeed('Nexo Jornal', 'https://www.nexojornal.com.br/rss.xml',
        'Jornalismo explicativo do Brasil'),
    SuggestedFeed('piauí', 'https://piaui.folha.uol.com.br/feed/',
        'Reportagens longas e ensaios'),
  ]),
  SuggestedRegion('South Asia', countries: {'IN', 'PK', 'BD', 'LK', 'NP'},
      feeds: [
        SuggestedFeed('Scroll', 'https://feeds.feedburner.com/ScrollinArticles.rss',
            'Reporting and culture from India'),
      ]),
  SuggestedRegion('East & Southeast Asia',
      countries: {'JP', 'CN', 'HK', 'TW', 'KR', 'SG', 'MY', 'TH', 'VN', 'PH',
        'ID'},
      languages: {'ja', 'zh', 'ko'},
      feeds: [
        SuggestedFeed('The Diplomat', 'https://thediplomat.com/feed/',
            'Politics and society across the Asia-Pacific'),
        SuggestedFeed('Sixth Tone', 'https://www.sixthtone.com/rss',
            'Everyday life in China'),
        SuggestedFeed('Nippon.com', 'https://www.nippon.com/en/feed/',
            'Japan explained, in depth'),
      ]),
  SuggestedRegion('Africa',
      countries: {'ZA', 'NG', 'KE', 'GH', 'ET', 'TZ', 'UG', 'ZW', 'RW', 'SN'},
      feeds: [
        SuggestedFeed('Daily Maverick',
            'https://www.dailymaverick.co.za/dmrss/',
            'Investigations and opinion from South Africa'),
        SuggestedFeed('Africa Is a Country', 'https://africasacountry.com/feed',
            'Politics and culture from the left, across the continent'),
      ]),
  SuggestedRegion('Australia & New Zealand', countries: {'AU', 'NZ'},
      feeds: [
        SuggestedFeed('The Conversation Australia',
            'https://theconversation.com/au/articles.atom',
            'Academics write about their research'),
      ]),
];

/// The regions to offer, the reader's own first; then everywhere-reads,
/// then the rest.
List<SuggestedRegion> regionsFor(Locale locale) {
  final local = regions.where((r) => r.matches(locale)).toList();
  return [
    ...local,
    everywhere,
    ...regions.where((r) => !local.contains(r)),
  ];
}

/// Pre-selected: the first three everywhere-reads and the reader's own
/// region.
Set<String> preselectedFor(Locale locale) => {
      ...everywhere.feeds.take(3).map((f) => f.url),
      for (final region in regions.where((r) => r.matches(locale)))
        ...region.feeds.map((f) => f.url),
    };
