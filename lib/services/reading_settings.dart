import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Typefaces offered for reading. The serif default is the system's; the
/// others are bundled, so they look the same on every device, offline.
enum ReadingFont {
  serif('Serif', 'Georgia', ['Times New Roman', 'Noto Serif', 'serif']),
  literata('Literata', 'Literata', ['serif']),
  sans('Sans-serif', 'Roboto', ['sans-serif']),
  hyperlegible(
      'Atkinson Hyperlegible', 'Atkinson Hyperlegible', ['sans-serif']);

  final String label;
  final String family;
  final List<String> fallback;
  const ReadingFont(this.label, this.family, this.fallback);
}

/// How articles are laid out: text size, typeface, side margins, and
/// whether the reader scrolls or turns pages.
@immutable
class ReadingPrefs {
  static const minFontSize = 14.0;
  static const maxFontSize = 30.0;
  static const minMargin = 0.0;
  static const maxMargin = 200.0;

  final double fontSize;
  final ReadingFont font;

  /// Side margin in logical pixels; null = automatic (a comfortable column
  /// on tablets, 20 on phones).
  final double? margin;

  /// Turn pages instead of scrolling.
  final bool paginated;

  const ReadingPrefs({
    this.fontSize = 18,
    this.font = ReadingFont.serif,
    this.margin,
    this.paginated = false,
  });

  /// The automatic margin for a screen [width] wide: text capped to a
  /// ~680px column on tablets, 20px on each side on phones.
  static double autoMargin(double width) =>
      width > 720 ? (width - 680) / 2 : 20.0;

  /// The side margin to use on a screen [width] wide, never leaving the
  /// text column narrower than 240px.
  double marginFor(double width) {
    final m = margin ?? autoMargin(width);
    final most = ((width - 240) / 2).clamp(0.0, double.infinity);
    return m.clamp(0.0, most);
  }

  ReadingPrefs copyWith({
    double? fontSize,
    ReadingFont? font,
    double? Function()? margin,
    bool? paginated,
  }) =>
      ReadingPrefs(
        fontSize: fontSize ?? this.fontSize,
        font: font ?? this.font,
        margin: margin == null ? this.margin : margin(),
        paginated: paginated ?? this.paginated,
      );

  @override
  bool operator ==(Object other) =>
      other is ReadingPrefs &&
      other.fontSize == fontSize &&
      other.font == font &&
      other.margin == margin &&
      other.paginated == paginated;

  @override
  int get hashCode => Object.hash(fontSize, font, margin, paginated);
}

/// The reading preferences, persisted, and observable so an open article
/// follows changes at once.
class ReadingSettings {
  ReadingSettings._();
  static final instance = ReadingSettings._();

  final ValueNotifier<ReadingPrefs> prefs = ValueNotifier(const ReadingPrefs());

  static const _kFontSize = 'reading_font_size';
  static const _kFont = 'reading_font';
  static const _kMargin = 'reading_margin';
  static const _kPaginated = 'reading_paginated';

  bool _loaded = false;

  Future<ReadingPrefs> load() async {
    if (_loaded) return prefs.value;
    final p = await SharedPreferences.getInstance();
    final fontName = p.getString(_kFont);
    prefs.value = ReadingPrefs(
      fontSize: (p.getDouble(_kFontSize) ?? 18)
          .clamp(ReadingPrefs.minFontSize, ReadingPrefs.maxFontSize),
      font: ReadingFont.values
              .where((f) => f.name == fontName)
              .firstOrNull ??
          ReadingFont.serif,
      margin: p.getDouble(_kMargin),
      paginated: p.getBool(_kPaginated) ?? false,
    );
    _loaded = true;
    return prefs.value;
  }

  Future<void> update(ReadingPrefs next) async {
    prefs.value = next;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kFontSize, next.fontSize);
    await p.setString(_kFont, next.font.name);
    if (next.margin == null) {
      await p.remove(_kMargin);
    } else {
      await p.setDouble(_kMargin, next.margin!);
    }
    await p.setBool(_kPaginated, next.paginated);
  }

  @visibleForTesting
  void debugReset() {
    _loaded = false;
    prefs.value = const ReadingPrefs();
  }
}
