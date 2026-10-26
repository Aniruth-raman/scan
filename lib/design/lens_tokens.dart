import 'package:flutter/material.dart';

/// Design tokens recovered by measuring Microsoft Lens 16.0.18526.20136
/// (`com.microsoft.office.officelens`) on a 384 x 832 dp viewport.
///
/// Every constant traces back to either a decoded resource (`.rea/apktool`) or a
/// live on-device measurement (`.rea/shots`). Geometry is reimplemented from
/// measurement; no Microsoft assets, icon glyphs or copy are used.
abstract final class LensColor {
  // ---------------------------------------------------------------- brand --
  /// `officelens_theme_color` / `default_app_color`.
  static const accent = Color(0xFFD83B01);

  /// `lenshvc_default_theme_color` — the alternate/enterprise accent.
  static const accentAlt = Color(0xFF0086F0);

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
  /// Capture and crop are black in every theme. Lens has no dark variant of the
  /// editor either — it switches chrome by *stage*, not by system brightness.
  static const stageBlack = Color(0xFF000000);
  static const stageWhite = Color(0xFFFFFFFF);

  /// `lenshvc_capture_bottom_gradient`: #00000000 -> #99000000 at 270 degrees.
  static const scrimClear = Color(0x00000000);
  static const scrimSolid = Color(0x99000000);

  /// `lenshvc_k2_rounded_corner_background`.
  static const trayFill = Color(0x80404040);
  static const trayStroke = Color(0x66606060);

  /// `lenshvc_page_number_background`, the review stage's page chip.
  static const pageNumberFill = Color(0xB3303030);

  /// `lenshvc_color_black_30`.
  static const black30 = Color(0x4D000000);
  static const white70 = Color(0xB4FFFFFF);

  // ------------------------------------------------------- editor stage --
  /// `lenshvc_k2_feature_tray_background` — the post-capture tray is a far
  /// darker plate than the capture tray (`#CC171717` vs `#80404040`).
  static const editorTrayFill = Color(0xCC171717);

  /// `lenshvc_postcapture_close_text` — "Options" and the action labels.
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

  /// `lensPackaging_Handle_color`.
  static const sheetHandle = Color(0xFF919191);

  static const disabled = Color(0xFF919191);
  static const danger = Color(0xFFB00020);

  /// Paper colour used behind page previews while they load.
  static const paper = Color(0xFFF7F7F7);
}

/// Spacing ladder. Lens works in 4 dp multiples; 16 dp is the page gutter.
abstract final class LensSpace {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// Corner ladder: 4 card, 8 hero, 12 thumbnail, 16 tray.
abstract final class LensRadius {
  static const card = 4.0;
  static const hero = 8.0;
  static const thumb = 12.0;
  static const tray = 16.0;
  static const pill = 28.0;
}

/// Measured geometry. Two interactive heights only: 48 and 40 (hero).
abstract final class LensSize {
  /// Every touch target is 48 dp.
  static const touch = 48.0;

  /// `lenshvc_k2_hero_btn_height` — full-width pill actions.
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

  /// `lenshvc_crop_magnifier_diameter` — the loupe shown while a corner moves.
  static const magnifier = 80.0;

  /// `lenshvc_crop_magnifier_boundary` — the loupe's white ring.
  static const magnifierBorder = 2.0;

  /// How far the loupe sits above the finger, so the corner stays visible.
  static const magnifierGap = 24.0;

  static const icon = 24.0;
  static const iconSmall = 20.0;

  /// `lenshvc_CollectionViewPageNumber_container_width` — the review stage's
  /// page chip, 37 x 28 dp (`lenshvc_viewpager_peak_size`) with a 4 dp radius.
  static const pageNumberWidth = 37.0;
  static const pageNumberHeight = 28.0;

  /// `lenshvc_packaging_sheet_handle`
  static const sheetHandleWidth = 36.0;
  static const sheetHandleHeight = 4.0;

  /// Measured Options sheet peek: 2205 - 1755 = 450 px = 160 dp.
  static const sheetPeek = 160.0;
}

/// Type scale. Lens uses Roboto (Android `sans-serif` / `sans-serif-medium`),
/// which is Flutter's default face, so no font asset is required.
abstract final class LensType {
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
abstract final class LensMotion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 300);

  static const curve = Curves.easeOutCubic;
  static const emphasized = Curves.easeOutQuart;
}

/// Stage-scoped palettes.
///
/// Capture and crop read from [LensChrome.dark]; list and editor from
/// [LensChrome.light]. Screens pick a chrome explicitly — there is deliberately
/// no `Brightness` switch anywhere in the UI layer.
@immutable
class LensChrome {
  const LensChrome({
    required this.background,
    required this.foreground,
    required this.secondary,
    required this.divider,
  });

  final Color background;
  final Color foreground;
  final Color secondary;
  final Color divider;

  static const dark = LensChrome(
    background: LensColor.stageBlack,
    foreground: LensColor.gray0,
    secondary: LensColor.white70,
    divider: LensColor.black30,
  );

  static const light = LensChrome(
    background: LensColor.gray0,
    foreground: LensColor.gray10,
    secondary: LensColor.gray7,
    divider: LensColor.gray3,
  );
}
