import 'package:flutter/material.dart';

/// E-ink friendly theme: pure black on pure white, no animations, no
/// ripples, no shadows — everything that causes ghosting on e-paper.
ThemeData buildEinkTheme() {
  const black = Colors.black;
  const white = Colors.white;

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: black,
      onPrimary: white,
      secondary: black,
      onSecondary: white,
      surface: white,
      onSurface: black,
      outline: black,
      error: black,
      onError: white,
    ),
    scaffoldBackgroundColor: white,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: const Color(0xFFE0E0E0),
    hoverColor: Colors.transparent,
  );

  return base.copyWith(
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      // Instant page switches: animations smear badly on e-ink.
      TargetPlatform.android: _NoTransitionsBuilder(),
      TargetPlatform.iOS: _NoTransitionsBuilder(),
      TargetPlatform.macOS: _NoTransitionsBuilder(),
      TargetPlatform.linux: _NoTransitionsBuilder(),
      TargetPlatform.windows: _NoTransitionsBuilder(),
    }),
    appBarTheme: AppBarTheme(
      backgroundColor: white,
      foregroundColor: black,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: const Border(bottom: BorderSide(color: black, width: 1)),
      // Derive from the base typography so the platform font family is kept.
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: black,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: const DividerThemeData(color: black, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(
      textColor: black,
      iconColor: black,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: black,
        side: const BorderSide(color: black, width: 1.5),
        shape: const RoundedRectangleBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: base.textTheme.labelLarge
            ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: black,
        shape: const RoundedRectangleBorder(),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: black, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: black, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: black, width: 2.5),
      ),
      labelStyle: TextStyle(color: black),
      hintStyle: TextStyle(color: Color(0xFF666666)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: black,
      contentTextStyle:
          base.textTheme.bodyMedium?.copyWith(color: white, fontSize: 15),
      behavior: SnackBarBehavior.fixed,
      shape: const RoundedRectangleBorder(),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: black,
      linearTrackColor: white,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: black,
      selectionColor: Color(0xFFBBBBBB),
      selectionHandleColor: black,
    ),
  );
}

/// Serif stack for long-form reading; falls back across iOS and Android.
const readingFontFamily = 'Georgia';
const readingFontFallback = ['Times New Roman', 'Noto Serif', 'serif'];

/// Grey wash used to mark saved highlights (renders well on e-paper).
const highlightBackground = Color(0xFFC9C9C9);

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
