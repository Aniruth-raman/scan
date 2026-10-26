import 'package:flutter/material.dart';

/// Design tokens for Scan.
///
/// Geometry was measured against a reference document scanner on a
/// 384 x 832 dp viewport; the layout constants trace back to those measurements
/// (`.rea/apktool`, `.rea/shots`). Nothing here is a copy of another app's
/// assets: the palette, the icon, the icons and the copy are ours.
abstract final class ScanColor {
  // ---------------------------------------------------------------- brand --
  /// The shutter blue: the launcher mark and the single accent in the UI.
  static const accent = Color(0xFF0B57D0);

  /// A lighter blue for accents that sit on the dark stage.
  static const accentLight = Color(0xFF4D8DF0);

  // ---------------------------------------------------- grey ramp (G0-G11) --
  static const gray0 = Color(0xFFFFFFFF);
  static const gray1 = Color(0xFFFAFAFA);
  static const gray2 = Color(0xFFF1F1F1);
  static const gray3 = Color(0xFFE6E6E6);
  static const gray4 = Color(0xFFE0E0E0);
  static const gray5 = Color(0xFFD8D8D8);
  static const gray6 = Color(0xFFB3B3B3);
  static const gray7 = Color(0xFF767676);
  static const gray8 = Color(0xFF666666);
  static const gray9 = Color(0xFF333333);
  static const gray10 = Color(0xFF212121);
  static const gray11 = Color(0xFF000000);

  // ---------------------------------------------------------- stage chrome --
  /// Capture and crop are black in every theme. Scan has no dark variant of
  /// the editor either - it switches chrome by *stage*, not by system brightness.
  static const stageBlack = Color(0xFF000000);
  static const stageWhite = Color(0xFFFFFFFF);

  /// : #00000000 -> #99000000 at 270 degrees.
  static const scrimClear = Color(0x00000000);
  static const scrimSolid = Color(0x99000000);

  /// .
  static const trayFill = Color(0x80404040);
  static const trayStroke = Color(0x66606060);

  /// , the review stage's page chip.
  static const pageNumberFill = Color(0xB3303030);

  /// .
  static const black30 = Color(0x4D000000);
  static const white70 = Color(0xB4FFFFFF);

  // ------------------------------------------------------- editor stage --
  ///  — the post-capture tray is a far
  /// darker plate than the capture tray (`#CC171717` vs `#80404040`).
  static const editorTrayFill = Color(0xCC171717);

  ///  — "Options" and the action labels.
  static const editorText = Color(0xFFD6D6D6);

  /// Measured tint of an enabled action icon on black.
  static const editorIcon = Color(0xFFADADAD);

  /// Measured tint of a disabled action icon/label.
  static const editorDisabled = Color(0xFF5C5C5C);

  // ----------------------------------------------------------- sheets --
  /// Measured section band inside the options sheet.
  static const sheetBand = Color(0xFFF2F2F2);

  /// Measured section-header text on that band.
  static const sheetHeader = Color(0xFF4A4A4A);

  /// .
  static const sheetHandle = Color(0xFF919191);

  /// `info_recent_files` / `info_recent_files_caption` — the band under the
  /// scan menu that names where the file lives.
  static const locationBand = Color(0xFFE5E5E5);
  static const locationCaption = Color(0xFF595959);

  static const disabled = Color(0xFF919191);
  static const danger = Color(0xFFB00020);

  /// Paper colour used behind page previews while they load.
  static const paper = Color(0xFFF7F7F7);
}

/// Spacing ladder. The design works in 4 dp multiples; 16 dp is the page gutter.
abstract final class ScanSpace {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// Corner ladder: 4 card, 8 hero, 12 thumbnail, 16 tray.
abstract final class ScanRadius {
  static const card = 4.0;
  static const hero = 8.0;
  static const thumb = 12.0;
  static const tray = 16.0;
  static const pill = 28.0;
}

/// Measured geometry. Two interactive heights only: 48 and 40 (hero).
abstract final class ScanSize {
  /// Every touch target is 48 dp.
  static const touch = 48.0;

  ///  — full-width pill actions.
  static const heroHeight = 40.0;

  /// Measured capture ring: 191 px / 2.8125 = 68 dp.
  static const captureRing = 68.0;
  static const captureStroke = 6.0;

  /// Measured "My Scans" toolbar: 201 px = 71.5 dp.
  static const appBarHeight = 71.5;

  /// Measured post-capture top bar: 136 px = 48 dp.
  static const editorBarHeight = 48.0;

  /// `feature_tray_width` / `feature_tray_item_height`.
  static const trayWidth = 48.0;
  static const trayItem = 48.0;

  /// Measured editor action row: 163 px = 58 dp.
  static const actionRow = 58.0;

  /// `bottom_bar_padding` — the editor's bottom navigation bar.
  static const editorNavPadding = 12.0;

  /// Measured editor feature tray: 48 x 193 dp (four 48 dp items).
  static const editorTrayWidth = 48.0;

  /// Measured crop filmstrip band: 270 px = 96 dp.
  static const filmstrip = 96.0;

  /// Measured filmstrip page thumbnail: 146 x 191 px = 52 x 68 dp.
  static const filmThumbWidth = 52.0;
  static const filmThumbHeight = 68.0;

  /// Measured capture-corner thumbnail ("done" target).
  static const cornerThumb = 58.0;

  /// Measured "My Scans" capture button.
  static const scanFab = 48.0;

  ///  — the loupe shown while a corner moves.
  static const magnifier = 80.0;

  ///  — the loupe's white ring.
  static const magnifierBorder = 2.0;

  /// How far the loupe sits above the finger, so the corner stays visible.
  static const magnifierGap = 24.0;

  static const icon = 24.0;
  static const iconSmall = 20.0;

  ///  — the review stage's
  /// The review stage's page chip, 37 x 28 dp with a 4 dp radius.
  static const pageNumberWidth = 37.0;
  static const pageNumberHeight = 28.0;

  /// `fragment_recent_items_info_parent` — the file-location band in the scan
  /// menu.
  static const locationBandHeight = 46.0;

  /// The 36 x 4 dp grab handle above every sheet.
  static const sheetHandleWidth = 36.0;
  static const sheetHandleHeight = 4.0;

  /// Measured Options sheet peek: 2205 - 1755 = 450 px = 160 dp.
  static const sheetPeek = 160.0;
}

/// Type scale. Roboto (Android `sans-serif` / `sans-serif-medium`) is
/// Flutter's default face, so no font asset is required.
abstract final class ScanType {
  /// Sheet header, e.g. "Save as".
  static const sheet = 20.0;

  /// App-bar title, e.g. "My Scans".
  static const appBar = 17.0;

  /// Hero/pill labels, tabs, tray labels.
  static const body = 14.0;

  /// Sheet row label, e.g. "Gallery" / "Image" in the options sheet.
  static const row = 16.0;

  /// Card footers, mode carousel.
  static const label = 12.0;
  static const micro = 10.0;
  static const nano = 8.0;

  /// The mode carousel is the single most recognisable type cue:
  /// uppercase, tracked, 12 sp.
  static const carouselTracking = 1.2;
}

/// Motion. Durations are calibrated for feel, not recovered from the binary.
abstract final class ScanMotion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);

  static const curve = Curves.easeOutCubic;
  static const emphasized = Curves.easeOutQuart;
}

/// Stage-scoped palettes.
///
/// Capture and crop read from [ScanChrome.dark]; list and editor from
/// [ScanChrome.light]. Screens pick a chrome explicitly — there is deliberately
/// no `Brightness` switch anywhere in the UI layer.
@immutable
class ScanChrome {
  const ScanChrome({
    required this.background,
    required this.foreground,
    required this.secondary,
    required this.divider,
  });

  final Color background;
  final Color foreground;
  final Color secondary;
  final Color divider;

  static const dark = ScanChrome(
    background: ScanColor.stageBlack,
    foreground: ScanColor.gray0,
    secondary: ScanColor.white70,
    divider: ScanColor.black30,
  );

  static const light = ScanChrome(
    background: ScanColor.gray0,
    foreground: ScanColor.gray10,
    secondary: ScanColor.gray7,
    divider: ScanColor.gray3,
  );
}
