import 'package:flutter/material.dart';

import '../services/reading_settings.dart';

/// Settings → Reading: text size, typeface, side margins and paged reading,
/// with a preview of a page as it will look.
class ReadingSettingsPanel extends StatefulWidget {
  const ReadingSettingsPanel({super.key});

  @override
  State<ReadingSettingsPanel> createState() => _ReadingSettingsPanelState();
}

class _ReadingSettingsPanelState extends State<ReadingSettingsPanel> {
  final _settings = ReadingSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  void _update(ReadingPrefs next) => _settings.update(next);

  static const _label = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return ValueListenableBuilder<ReadingPrefs>(
      valueListenable: _settings.prefs,
      builder: (context, prefs, _) {
        final margin = prefs.marginFor(screenWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Preview(prefs: prefs, screenWidth: screenWidth),
            const SizedBox(height: 20),
            Text('Text size: ${prefs.fontSize.round()}', style: _label),
            Slider(
              value: prefs.fontSize,
              min: ReadingPrefs.minFontSize,
              max: ReadingPrefs.maxFontSize,
              divisions: 8,
              label: '${prefs.fontSize.round()}',
              onChanged: (v) => _update(prefs.copyWith(fontSize: v)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                      prefs.margin == null
                          ? 'Margins: automatic'
                          : 'Margins: ${margin.round()} px',
                      style: _label),
                ),
                if (prefs.margin != null)
                  TextButton(
                    onPressed: () => _update(prefs.copyWith(margin: () => null)),
                    child: const Text('Use automatic'),
                  ),
              ],
            ),
            Slider(
              value: margin.clamp(ReadingPrefs.minMargin, ReadingPrefs.maxMargin),
              min: ReadingPrefs.minMargin,
              max: ReadingPrefs.maxMargin,
              divisions: 40,
              label: '${margin.round()} px',
              onChanged: (v) => _update(prefs.copyWith(margin: () => v)),
            ),
            const SizedBox(height: 8),
            const Text('Font', style: _label),
            RadioGroup<ReadingFont>(
              groupValue: prefs.font,
              onChanged: (f) {
                if (f != null) _update(prefs.copyWith(font: f));
              },
              child: Column(
                children: [
                  for (final font in ReadingFont.values)
                    RadioListTile<ReadingFont>(
                      contentPadding: EdgeInsets.zero,
                      value: font,
                      title: Text(font.label,
                          style: TextStyle(
                              fontSize: 18,
                              fontFamily: font.family,
                              fontFamilyFallback: font.fallback)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Turn pages instead of scrolling'),
              subtitle: const Text(
                  'Articles move one screen at a time: use the arrows at the '
                  'bottom, swipe, or press the page keys. Shows "Page 2 / 5".'),
              value: prefs.paginated,
              onChanged: (v) => _update(prefs.copyWith(paginated: v)),
            ),
          ],
        );
      },
    );
  }
}

/// A page of sample text with the chosen font, size and margins (scaled to
/// the preview's width, so the proportions match the real screen).
class _Preview extends StatelessWidget {
  final ReadingPrefs prefs;
  final double screenWidth;

  const _Preview({required this.prefs, required this.screenWidth});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final scale = constraints.maxWidth / screenWidth;
      final style = TextStyle(
        fontSize: prefs.fontSize * scale.clamp(0.7, 1.0),
        height: 1.55,
        fontFamily: prefs.font.family,
        fontFamilyFallback: prefs.font.fallback,
        color: Colors.black,
      );
      return Container(
        key: const Key('readingPreview'),
        decoration: BoxDecoration(border: Border.all(width: 1.5)),
        padding: EdgeInsets.symmetric(
            horizontal: prefs.marginFor(screenWidth) * scale, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A calm place to read',
                style: style.copyWith(
                    fontSize: style.fontSize! + 6, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Reading on paper-like screens should feel unhurried. Pick the '
              'size, typeface and margins that make long articles easy on '
              'your eyes, and decide whether pages scroll or turn.',
              style: style,
            ),
          ],
        ),
      );
    });
  }
}
