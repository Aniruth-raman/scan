import 'package:flutter/material.dart';

import 'scan_tokens.dart';

/// Theme construction for the two stages.
///
/// The colour scheme is written out explicitly rather than generated with
/// `ColorScheme.fromSeed`: seeding a Material 3 tonal palette invents a
/// surface ramp the design does not have and softens the accent.
abstract final class ScanTheme {
  /// List and editor stage: white surface, dark text.
  static ThemeData editor() => _build(ScanChrome.light);

  /// Capture and crop stage: black surface, light text.
  static ThemeData capture() => _build(ScanChrome.dark);

  static ThemeData _build(ScanChrome chrome) {
    final scheme = ColorScheme(
      brightness: Brightness.light,
      primary: ScanColor.accent,
      // Hero-button content is white on the accent.
      onPrimary: ScanColor.gray0,
      primaryContainer: ScanColor.accent,
      onPrimaryContainer: ScanColor.gray11,
      secondary: ScanColor.gray10,
      onSecondary: ScanColor.gray0,
      secondaryContainer: ScanColor.gray2,
      onSecondaryContainer: ScanColor.gray10,
      error: ScanColor.danger,
      onError: ScanColor.gray0,
      surface: chrome.background,
      onSurface: chrome.foreground,
      surfaceContainerHighest: ScanColor.gray2,
      onSurfaceVariant: chrome.secondary,
      outline: ScanColor.gray5,
      outlineVariant: chrome.divider,
      shadow: ScanColor.gray11,
      scrim: ScanColor.gray11,
      inverseSurface: ScanColor.gray10,
      onInverseSurface: ScanColor.gray0,
      inversePrimary: ScanColor.accentLight,
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
      iconTheme: IconThemeData(color: chrome.foreground, size: ScanSize.icon),
      splashFactory: InkRipple.splashFactory,
      // Scan is a 48 dp app; do not let Material compact it.
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
        backgroundColor: ScanColor.gray10,
        contentTextStyle: text.bodyMedium?.copyWith(color: ScanColor.gray0),
        insetPadding: const EdgeInsets.all(ScanSpace.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ScanRadius.hero),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: chrome.divider,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ScanColor.accent,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: ZoomPageTransitionsBuilder()},
      ),
    );
  }

  /// Roboto is Flutter's default on Android, so no font asset is shipped.
  static TextTheme _text(ScanChrome chrome) {
    final fg = chrome.foreground;
    final secondary = chrome.secondary;

    return TextTheme(
      // 20 sp — sheet headers ("Save as").
      titleLarge: TextStyle(
        fontSize: ScanType.sheet,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      // 17 sp — app-bar titles ("My Scans").
      titleMedium: TextStyle(
        fontSize: ScanType.appBar,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      titleSmall: TextStyle(
        fontSize: ScanType.body,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.3,
      ),
      // 14 sp — hero labels, tabs, tray labels.
      bodyLarge: TextStyle(fontSize: ScanType.body, color: fg, height: 1.4),
      bodyMedium: TextStyle(fontSize: ScanType.body, color: fg, height: 1.4),
      // 12 sp — card footers, carousel.
      bodySmall: TextStyle(
        fontSize: ScanType.label,
        color: secondary,
        height: 1.35,
      ),
      labelLarge: TextStyle(
        fontSize: ScanType.body,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.2,
      ),
      labelMedium: TextStyle(
        fontSize: ScanType.label,
        fontWeight: FontWeight.w500,
        color: fg,
        height: 1.2,
      ),
      labelSmall: TextStyle(
        fontSize: ScanType.micro,
        fontWeight: FontWeight.w500,
        color: secondary,
        height: 1.2,
      ),
    );
  }
}

/// Named text styles for the custom chrome widgets, which cannot rely on
/// `Theme.of(context).textTheme` alone for the exact tracking the design needs.
abstract final class ScanText {
  /// App-bar title: 17 sp medium.
  static TextStyle appBar(Color color) => TextStyle(
    fontSize: ScanType.appBar,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.3,
  );

  /// Sheet header: 20 sp medium.
  static TextStyle sheet(Color color) => TextStyle(
    fontSize: ScanType.sheet,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.3,
  );

  /// Hero/pill label: 14 sp medium.
  static TextStyle hero(Color color) => TextStyle(
    fontSize: ScanType.body,
    fontWeight: FontWeight.w500,
    color: color,
    height: 1.2,
  );

  /// Mode carousel: uppercase, tracked, 12 sp. The signature cue.
  static TextStyle carousel(Color color, {bool selected = false}) => TextStyle(
    fontSize: ScanType.label,
    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
    letterSpacing: ScanType.carouselTracking,
    color: color,
    height: 1.2,
  );

  /// Card footer title: 12 sp.
  static TextStyle cardTitle(Color color) => TextStyle(
    fontSize: ScanType.label,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.2,
  );

  static TextStyle caption(Color color) => TextStyle(
    fontSize: ScanType.micro,
    fontWeight: FontWeight.w400,
    color: color,
    height: 1.2,
  );
}
