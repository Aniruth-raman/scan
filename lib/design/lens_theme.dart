import 'package:flutter/material.dart';

import 'lens_tokens.dart';

/// Theme construction for the two Lens stages.
///
/// The colour scheme is written out explicitly rather than generated with
/// `ColorScheme.fromSeed`. Seeding a Material 3 tonal palette from
/// `#D83B01` desaturates the accent and invents a surface ramp that Lens does
/// not have — that is exactly how the previous build ended up looking generic.
abstract final class LensTheme {
  /// List and editor stage: white surface, dark text.
  static ThemeData editor() => _build(LensChrome.light);

  /// Capture and crop stage: black surface, light text.
  static ThemeData capture() => _build(LensChrome.dark);

  static ThemeData _build(LensChrome chrome) {
    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: LensColor.accent,
      // Lens renders hero-button content black on accent, not white.
      onPrimary: LensColor.gray11,
      primaryContainer: LensColor.accent,
      onPrimaryContainer: LensColor.gray11,
      secondary: LensColor.gray10,
      onSecondary: LensColor.gray0,
      secondaryContainer: LensColor.gray2,
      onSecondaryContainer: LensColor.gray10,
      error: LensColor.danger,
      onError: LensColor.gray0,
      surface: chrome.background,
      onSurface: chrome.foreground,
      surfaceContainerHighest: LensColor.gray2,
      onSurfaceVariant: chrome.secondary,
      outline: LensColor.gray5,
      outlineVariant: chrome.divider,
      shadow: LensColor.gray11,
      scrim: LensColor.gray11,
      inverseSurface: LensColor.gray10,
      onInverseSurface: LensColor.gray0,
      inversePrimary: LensColor.accentAlt,
    );

    final text = _text(chrome);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: chrome.background,
      canvasColor: chrome.background,
      dividerColor: chrome.divider,
      textTheme: text,
      primaryTextTheme: text,
      iconTheme: IconThemeData(color: chrome.foreground, size: LensSize.icon),
      splashFactory: InkRipple.splashFactory,
      // Lens is a 48 dp app; do not let Material compact it.
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: AppBarTheme(
        backgroundColor: chrome.background,
        foregroundColor: chrome.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: LensColor.gray10,
        contentTextStyle: text.bodyMedium?.copyWith(color: LensColor.gray0),
        insetPadding: const EdgeInsets.all(LensSpace.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LensRadius.hero),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: chrome.divider,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: LensColor.accent,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: ZoomPageTransitionsBuilder()},
      ),
    );
  }

  /// Roboto is Flutter's default on Android and is also what Lens uses
  /// (`sans-serif` / `sans-serif-medium`), so no font asset is shipped.
  static TextTheme _text(LensChrome chrome) {
    final fg = chrome.foreground;
    final secondary = chrome.secondary;

    return TextTheme(
      // 20 sp — sheet headers ("Save as").
      titleLarge: TextStyle(
        fontSize: LensType.sheet,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      // 17 sp — app-bar titles ("My Scans").
      titleMedium: TextStyle(
        fontSize: LensType.appBar,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      titleSmall: TextStyle(
        fontSize: LensType.body,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      // 14 sp — hero labels, tabs, tray labels.
      bodyLarge: TextStyle(fontSize: LensType.body, color: fg, height: 1.4),
      bodyMedium: TextStyle(fontSize: LensType.body, color: fg, height: 1.4),
      // 12 sp — card footers, carousel.
      bodySmall: TextStyle(
        fontSize: LensType.label,
        color: secondary,
        height: 1.35,
      ),
      labelLarge: TextStyle(
        fontSize: LensType.body,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.2,
      ),
      labelMedium: TextStyle(
        fontSize: LensType.label,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.2,
      ),
      labelSmall: TextStyle(
        fontSize: LensType.micro,
        fontWeight: FontWeight.w500,
        color: secondary,
        height: 1.2,
      ),
    );
  }
}

/// Named text styles for the custom chrome widgets, which cannot rely on
/// `Theme.of(context).textTheme` alone for the exact tracking Lens uses.
abstract final class LensText {
  /// App-bar title: 17 sp medium.
  static TextStyle appBar(Color color) => TextStyle(
    fontSize: LensType.appBar,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.3,
  );

  /// Sheet header: 20 sp medium.
  static TextStyle sheet(Color color) => TextStyle(
    fontSize: LensType.sheet,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.3,
  );

  /// Hero/pill label: 14 sp medium.
  static TextStyle hero(Color color) => TextStyle(
    fontSize: LensType.body,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.2,
  );

  /// Mode carousel: uppercase, tracked, 12 sp. The signature cue.
  static TextStyle carousel(Color color, {bool selected = false}) => TextStyle(
    fontSize: LensType.label,
    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
    letterSpacing: LensType.carouselTracking,
    color: color,
    height: 1.2,
  );

  /// Card footer title: 12 sp.
  static TextStyle cardTitle(Color color) => TextStyle(
    fontSize: LensType.label,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.2,
  );

  static TextStyle caption(Color color) => TextStyle(
    fontSize: LensType.micro,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.2,
  );
}
