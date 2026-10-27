?# Scan — build plan

Status: **P0–P9 shipped**; release APK **42,686,787 B**. Nothing pending — see §0 for the state and
`findings.md` for the evidence behind every measurement.

## 0. Where things stand (read this first)

**Identity.** The app is **Scan**, package `com.aniruth.scan`, Dart package `scan`. Accent
`#0B57D0` (dark blue) with white content on it; the launcher mark is a white **page with a cut
corner** on that same blue — one closed path, 40 × 54 dp with a 14 dp 45° chamfer, in
`res/drawable/ic_launcher_foreground.xml` (108 viewport, shared by the adaptive icon and its
`monochrome` layer, so it must stay a bare silhouette) plus its pre-26 twin
`res/mipmap-anydpi/ic_launcher.xml` (same page, 72 viewport, with the blue rect). Geometry, the
safe-zone maths and the 1.5× viewport trap: `findings.md` → "The launcher mark is a page, not
an aperture". The density PNG mipmaps are gone; `anydpi` covers API 24-25. Nothing in the app
carries another product's name, colour, icons or copy.

**Shipped, in order, all verified on the M34 (`RZCW9112DFP`, 1080×2340 @ 450 dpi = 384×832 dp):**

| commit | what |
|---|---|
| `178c0cd` | P0 design tokens + P0.5 native image kit (12.5 MP capture, `setPolyToPoly` warp, native PDF) |
| `0de3489` | P1 My Scans (71.5 dp bar, 4 dp tiles, 48 dp capture button) |
| `5f81f17` | P2 capture chrome (black stage, 48 dp tray, 68 dp ring, carousel, filmstrip, multi-page) |
| `2bdef5a` | P2.5 PDF writer (JPEG `DCTDecode` XObjects instead of `PdfDocument`) |
| `2cd9e45` | P3 crop stage (24 dp quad, 96 dp filmstrip, 40 dp hero) |
| `830d725` | D1 detection on M-LSD 320 TFLite instead of hand-written CV |
| `f8decb4` | P4 review & edit (measured chrome, per-page edits, options sheet, filters/reorder) |
| `df744ae` | P4.1 file names from the title, PDF published to `Download/Scan` |
| `1b54730` | P4.2 `QuadSmoother` (no more hopping outline) + 80 dp corner loupe |
| `364e3e4` | P4.3 a PDF save is its own record again (JPEG + PDF tiles) |
| `ca96a4c` | P5 shared hero pill, eased carousel, integration flows rewritten |
| P6 | auto capture, review page chip, corner guard |
| P7 | the scan menu names the file's location (Phone Storage > Pictures > Scan) |
| P8 | the shared folders are indexed; deletes follow ownership |
| 86c14fe | P9 renamed to **Scan**: com.aniruth.scan, blue identity, own shutter icon |

**Pending:** nothing. The "60 fps" criterion still has no number — this ROM exposes no frame
statistics — see §8 P5 for what was measurable.

**Test surface.** `flutter test` = 46 unit/widget tests (`document_detector` incl. the quad guard,
`quad_smoother`, `scan_exporter`, `review_screen`, `history`). `flutter test
integration_test/app_flow_test.dart -d <device>` = the two on-device flows (image and PDF, with
auto capture switched off through the More sheet).
`integration_test/camera_probe_test.dart` is a diagnostic, not an assertion.

**Rules that keep biting** (all from `AGENTS.md`): no new dependency, asset or ABI without saying
so first; platform/Flutter API before hand-written code; `lens.apk` is read-only evidence; every
change ends with `flutter analyze` + `flutter test` + a release-APK size delta against
**42,686,787 B**.

**Where the evidence lives.** `findings.md` holds every decoded value with its resource name
(geometry, colours, the tray/sheet/loupe dimensions, the saving model). `.rea/apktool/` is the
full resource decode, `.rea/shots/` the screenshots (`ui-*.xml` are the *original's* hierarchy
dumps; `p4-*`/`p8-*` are ours). `plan.md` §3 is the measured design system, §8 the progress log.
None of those dumps, screenshots or the APK are published — this repository carries the
measurements, not the app.

---

## 1. REA setup — verified

| Check | State |
|---|---|
| `rea doctor` | `healthy: true` |
| JADX provider | available (`jadx-headless-mcp-0.7.1-all.jar`) |
| apktool | configured and used (`.rea/apktool/` holds a full decode) |
| REA MCP server | connected, 207 tools |
| ADB provider | **fixed this session** — `REA_ADB_PATH` set to `C:\Users\aniruth\android-sdk\platform-tools\adb.exe` (user env). The running MCP server keeps its spawn-time env, so the REA adb tools start working after an OpenCode restart. Direct `adb` calls work now. |
| Hopper / Ghidra / IDA / Kuna | absent — irrelevant, target is Java/Kotlin, not native |

Non-issues: `installations.state: multiple` and the `jadx ... classification: config_drift` line are cosmetic; both binaries resolve.

**Device attached:** `RZGL61WG5QP` — SM-S938B, Android 17, **1080×2340 @ 450 dpi = 384×832 dp**, 34 dp status bar, 48 dp nav bar. This is the reference viewport for every measurement below.

---

## 2. What the target actually is

`lens.apk` (SHA-256 `6757a427…cb55a`) is **Microsoft Lens / Office Lens 16.0.18526.20136**, `com.microsoft.office.officelens`, minSdk 24 / targetSdk 34. 21,105 classes, ~1,860 English strings across 93 locales.

Native Java/Kotlin, R8-minified — `identify_flutter_build` returns `flutter_detected: false`. So there is **no Flutter/Riverpod/RN source to lift**. Everything below was recovered from resources, layout XML, and live measurement of the same build installed on the device.

Stack (from META-INF module list + class search):
- **CameraX** `camera-view` + `camera2` (`ExperimentalAnalyzer` for frame analysis)
- **ML Kit** `text-recognition`, `image-labeling`, `tflite` (GPU + support)
- First-party feature modules: `lenscapture`, `lenscommonactions` (crop), `lensgallery`, `lensocr`, `lensink`, `lensimagelabeler`, `lenspackaging`, `lenstextsticker`, `lensuilibrary`, `libletapphost`
- `pdfbox-android` for PDF write, Room + DataStore for local state

---

## 3. The design system (extracted, not guessed)

### Color

| Token | Value | Use |
|---|---|---|
| `officelens_theme_color` | `#D83B01` | the reference app's accent — **not shipped**: Scan uses `#0B57D0` |
| `lenshvc_default_theme_color` | `#0086F0` | alternate/enterprise accent |
| Camera chrome | `#000000` | capture + crop backgrounds |
| Bottom scrim | `#00000000 → #99000000`, 270° | legibility over live preview |
| Feature tray | fill `#80404040`, stroke 1dp `#66606060` | translucent pill tray |
| Neutral ramp | `#FFFFFF #FAFAFA #F1F1F1 #E6E6E6 #E0E0E0 #D8D8D8 #B3B3B3 #767676 #666666 #333333 #212121 #000000` | Gray0 → Gray11 |
| Post-capture surface | `#FFFFFF` | edit surface |
| Crop info card | `#FFFFFF` on `#4D000000` | hint cards |
| Disabled text | `#919191` | discards |

There is **no dark-mode post-capture variant** — capture/crop are always black, edit/scan-list are always white. That is a constraint to preserve: the app does not follow system dark mode; it switches chrome by stage.

### Geometry ladder

`4` (list card) · `8` (hero button) · `12` (thumbnail corners, capture-next button) · `16` (feature tray) · `28` (pill token) · `48` (every touch target)

### Type

| Size | Use |
|---|---|
| 20sp | sheet header ("Save as") |
| 17sp | app-bar title ("My Scans") |
| 14sp | hero button label, pill label, tabs, tray labels |
| 12sp | card footer title, mode carousel (uppercase, tracked) |
| 10sp | secondary tray labels |
| 8sp | carousel micro-labels |

Uppercase + letter-spacing on the mode carousel is the single most recognisable type cue.

### Measured screens (dp, on a 384 dp-wide viewport)

**Capture**
- status bar 34 → toolbar starts +15.6; gallery/"My Scans" icon 48×48 at x=20
- feature tray 48 wide, item 48 tall, right margin 12, top offset 12, elevation 10 (Flash / More Options)
- capture ring **68×68**, dead-centre horizontally, ring stroke 6
- bottom strip 48 tall: Import 24 icon at x=15, then mode carousel inset 48 each side, 12sp `ACTIONS · SCAN · WHITEBOARD · BUSINESS CARD`
- camera viewport ends 116 dp above bottom of screen — the toolbar is chrome on scrim, not a layout row

**My Scans**
- toolbar 71.5 tall; 32 dp back at x=16; title 17sp optically centred
- cards: 4 dp radius, 20 dp elevation, square preview, 48 dp bottom gradient, 32 dp footer = type icon + 12sp title + overflow
- empty: "You don't have any items yet", centred
- FAB 48 dp at 16 from right, 40 above nav bar

**Crop**
- pure black; quad inset **24 dp** left/right/top
- 48 dp back at top-left; right tray 3×48 (Rotate / Retake / Reset) at 8 dp end margin, vertically centred
- filmstrip 96 dp: page thumb 52×68, then "add more" 52×85
- hero "Review and Edit" 40 dp tall, 16 dp margins, 8 dp radius, 14sp + chevron at 8 dp gap
- corner drag shows a magnifier circle at elevation 8

**Review & Edit** — *black, not white*: the root is `@color/lenshvc_black` and the bottom bar is
`postCapture_bottomBar_color_coherence` = `#000000` (`postcapture_collection_view_k2.xml`,
`lens-state5.png`). Only the packaging sheet over it is white.
- 48 dp top bar (`guideline_top_margin`); 48 dp back target at 12 dp; "Options" 14 sp `#D6D6D6`
  flush to the end edge
- pager: image inset 16 dp, vertically centred
- feature tray 48 × 193 dp at 12 dp from the end, vertically centred; icon-only (the 14 sp label
  collapses at 48 dp wide), plate `#CC171717` + 1 dp `#66606060`, radius 16 dp
- action row 58 dp: 3 × 120 dp, 10 dp from the cell top, 24 dp icon over a 12 sp label
  (`#D6D6D6` enabled, `#5C5C5C` disabled — Reorder needs a second page)
- **Finish** hero: 48 dp container, 344 dp x 40 dp pill, 8 dp radius, accent fill, 24 dp check
  + 8 dp + 14 sp label, black on accent
- Options bottom sheet: 36×4 handle, 20 sp header at 16 dp, 12 sp `#F2F2F2` section bands,
  16 sp rows with 24 dp icons, 160 dp peek above the nav bar

---

## 4. Why `scan` reads as "not great"

Current state: 4 screens, ~1,300 LOC of UI, builds a 54.6 MB release APK.

1. **Wrong identity.** `ColorScheme.fromSeed(Color(0xFF1565C0))` - a generic Material 3 blue, neither the reference stage chrome nor our palette. Every pixel inherited the wrong hue.
2. **No design tokens.** Spacing, radii, and type are ad-hoc per screen. Nothing maps to the measured ladder above.
3. **Default widgets.** `AppBar` + `FloatingActionButton` where Lens uses a 71.5 dp custom bar and a 48 dp button at hard offsets.
4. **Chrome is wrong on camera/crop.** Black + scrim + 10 dp elevation tray is the whole feel; a themed surface doesn't survive contact with a live preview.
5. **Missing the affordances that make it comfortable.** No mode carousel, no feature tray, no filmstrip, no multi-page, no Options sheet, no hold-to-compare, no magnifier on corner drag.
6. **Detection quality.** Hand-rolled pure-Dart Otsu → convex hull → RDP → quad, at 240 px. That is the reason the live outline feels jittery versus Lens's ML Kit pipeline.

---

## 5. Constraints

### Hard constraints

| # | Constraint | Consequence |
|---|---|---|
| C1 | **No asset reuse.** Microsoft's icons, drawables, fonts, and string copy are copyrighted; "Lens"/"Office Lens" and the logo are trademarks. | Rebuild every icon from Material Symbols (rounded) to the same optical weight, and write our own copy. Geometry and spacing come from measurement; pixels do not. |
| C2 | **No source to port.** R8-minified, no Flutter, no sourcemaps. | This is a from-scratch reimplementation against measured behaviour, not a port. |
| C3 | **No Lens ML models.** The on-device detector is not redistributable. | Either hand-rolled CV (today) or `google_mlkit_document_scanner`; see Q3. |
| C4 | **`scan/` is not under version control.** Workspace is not a git repo. | Before any edit: `git init` + baseline commit, or a directory copy. Otherwise a rewrite is unrecoverable. |
| C5 | **Reference viewport is 384×832 dp.** | Design at 384 dp, but every screen must still survive 320–600 dp. Absolute offsets become `LayoutBuilder`-aware paddings. |
| C6 | **Flutter 3.47.8 / Dart 3.13.7 at `C:\Users\aniruth\flutter`**, not on PATH; Android SDK at `C:\Users\aniruth\android-sdk`. | All commands use absolute paths, or we add both to PATH. |
| C7 | **`compileSdk`/`targetSdk` are pinned to 37** because `permission_handler` requires it. | Keep. Does not affect UI work. |
| C8 | **No cloud.** No OneDrive/OneNote/Word/PowerPoint, no account, no MDM. | The Options sheet exposes PDF + Image + gallery only. |

### Design constraints worth stating explicitly

- **Stage-based chrome, not theme-based.** Capture and crop are black regardless of system theme; edit and list are white. Implementing one adaptive `ColorScheme` is the wrong move — it is what produced the current generic look.
- **The camera is the app.** Lens spends its visual budget on the preview: scrim gradients, translucent tray, oversized ring. Any non-transparent panel over the preview destroys it.
- **48 dp everywhere, 40 dp for hero pills.** Two values, no exceptions. This is most of the "comfy" feel.
- **Motion is load-bearing.** `animateLayoutChanges` on the tray, sheet peek→expand, press-scale on the ring, magnifier tracking the dragged corner. Static replicas of these layouts feel dead.

### Explicit non-goals

OCR/table extraction, immersive reader, business-card contacts, QR mode, video capture, Copilot, ink-to-text, multi-account, telemetry.

---

## 6. Proposed build

### Structure (additive — existing services stay)

```
lib/
  design/
    lens_tokens.dart      // colours, spacing ladder, radii, type scale
    lens_theme.dart       // stage-scoped ThemeData (capture/editor distinct)
  widgets/
    lens_app_bar.dart     // 71.5dp bar, 32dp back, 17sp centred title
    feature_tray.dart     // 48dp translucent vertical tray, animated
    hero_button.dart      // 40dp pill, 8dp radius
    capture_ring.dart     // 68dp ring, 6dp stroke, press scale
    mode_carousel.dart    // 12sp tracked uppercase, fading edges
    filmstrip.dart        // 52x68 page thumbs + add-more
    lens_sheet.dart       // 36x4 handle, 20sp header, peek
    empty_state.dart
  screens/                // capture, crop, review, gallery rebuilt
  services/               // UNCHANGED: edge_detector, worker, image ops,
                          //           repository, exporter
```

Existing `edge_detector.dart`, `edge_detection_worker.dart`, `document_image_ops.dart`, `scan_repository.dart`, `scan_exporter.dart` are kept and only wired into the new screens. That removes the risk of regressing the pipeline that already works.

### Phases

| Phase | Deliverable | Verification |
|---|---|---|
| **P0** | Baseline commit. `lens_tokens.dart` + `lens_theme.dart`. | `flutter analyze` clean; no visible change |
| **P1** | My Scans: 71.5 dp bar, 4 dp cards with gradient footer, 48 dp capture button at measured offsets, empty state | compare against `rea-shots/ui-myscans.xml`, empty + populated |
| **P2** | Capture: black stage, scrim, 48 dp tray, 68 dp ring, mode carousel, mini-gallery peek | overlay diff vs measured bounds; ring centre within 1 dp |
| **P3** | Crop: 24 dp quad inset, 48 dp tray, 96 dp filmstrip, 40 dp hero, magnifier + hold-to-compare | drag corners on device; quad tracks under finger |
| **P4** | Review & Edit: pager, 4-item tray, 58 dp action row, Finish hero, Options sheet | multi-page add/reorder; sheet peek 160 dp |
| **P5** | Motion + device pass: tray expand, sheet transitions, press scales, hero feedback, haptics | 60 fps on device, no jank on capture |

Each phase ends with a real install on `RZGL61WG5QP`, not just a widget test.

### Evidence artifacts already on disk

`.rea/shots/` (live hierarchy dumps for capture, crop, edit, options, my-scans, discard dialog), `findings.md`, `.rea/apktool/` (full resource decode). These are the acceptance references for P1–P4.

---

## 7. Decisions — LOCKED

| # | Decision | Resolution |
|---|---|---|
| Q1 | Fidelity | **Faithful, own assets.** Measured geometry, stage-based chrome, 48/40 dp rhythm. Material Symbols icons, our own copy. |
| Q2 | Scope | **Multi-page capture + filters.** No ink, no OCR. |
| Q3 | Detection | **Our UI primary, ML Kit opt-in.** See conflict note below. |
| Q4 | Rewrite policy | **In place**, git baseline `d799fef` first. |

### Q3 conflict, resolved

`google_mlkit_document_scanner` is not a detector — `scanDocument()` launches Google's
own full-screen scanner and returns cropped images plus a PDF. It exposes no API to feed
edge detection into a custom `CameraPreview`. Using it as the primary surface would delete
the ring, tray, mode carousel and filmstrip, i.e. the things that make Lens feel like Lens.

Resolution: **our capture + crop stay primary**; an `Auto scan` action in the feature tray
hands off to ML Kit for difficult documents. The faithful surface is preserved and the
high-accuracy path still exists.

One free win from the font audit: Lens uses `sans-serif` / `sans-serif-medium`, i.e.
**Roboto**, with no bundled brand face. Flutter's default is already Roboto, so type
matches without shipping a font. Only proprietary icon voices would have needed replacing.

### Baseline

`scan/` initialised as a git repo, baseline commit **`d799fef`** (`baseline: v1 (pre-rebuild)`), working tree clean.

---

## 8. Progress log

### P0 — design system ✅ `178c0cd`

`lens_tokens.dart`, `lens_theme.dart`, single light theme. Lens has no dark variant; chrome
is chosen per stage, never by system brightness.

### P0.5 — native image kit ✅ `178c0cd`

The old pipeline captured at **1280 x 720** (`ResolutionPreset.high` is 720p on Android) and
then degraded it further. Measured on device before/after:

| | before | after |
|---|---|---|
| capture | 1280 x 720 (0.9 MP) | **4080 x 3060 (12.5 MP)** |
| rectified page | 2048 px cap, CPU bilinear | **3043 x 3186**, `setPolyToPoly` |
| JPEG generations | 2–3 | 1 |
| PDF | Dart `pdf`, 28 pt margins | `PdfDocument`, full bleed |
| release APK | 54.6 MB | **50.5 MB** |

Every step is a platform wheel rather than a Dart reimplementation: `BitmapFactory` +
`ExifInterface` (with `inSampleSize` bounds), `Matrix.setPolyToPoly` + `Canvas.drawBitmap`
for rectification, `ColorMatrixColorFilter` for tones, `Bitmap.compress` for encoding,
`PdfDocument` for multi-page output, `FileProvider` + `ACTION_VIEW` for opening files.
`pdf` and `printing` are gone; the detector now receives a 480 px RGBA buffer from the
native decode instead of decoding a multi-megabyte JPEG in Dart.

### P1 — My Scans ✅

Re-measured against a **populated** My Scans on the real app (`.rea/shots/lens-myscans-grid.png`,
`ui-myscans-full.xml`):

- surface `#FAFAFA`, tiles `#FFFFFF`, radius 4 dp, shadow ≈12 % black / 4 dp blur
- tiles **176 x 176 dp**, 12 dp side inset, 8 dp gutter, 16 dp vertical gap
- bottom **48 dp fade to opaque white** (`list_item_gradient`), 32 dp footer, 12 sp title
  in `#767676`, 24 dp overflow inset 4 dp
- capture button **48 dp circle**, accent, 16 dp end / 40 dp bottom
- bar 71.5 dp, centred 17 sp title, empty-state text `#646464` at 14 sp

Verified on device — first tile and FAB landed at `[34,342][529,837]` and
`[900,1958][1035,2093]`, against the original's `[34,342][529,837]` / `[900,1957][1035,2092]`.

Two platform deviations, both forced by Android 15 edge-to-edge:

1. The status bar cannot be painted black (`statusBarColor` is ignored), so it shows the
   #FAFAFA surface with **dark** glyphs. Painting it black would have left white glyphs on
   a light bar.
2. `window.isNavigationBarContrastEnforced = false` in `MainActivity` removes the system's
   black scrim so the nav bar shows the surface, as the original does.

### P2 — capture chrome ✅

Rebuilt the capture stage against `ui-camera.xml` + `lens-state1.png`. Structure, measured:

- **status bar is a solid black band** — the preview starts below it and stops at the
  filmstrip; the shutter/carousel band underneath is black, not preview
- dismiss chevron: 48 dp target at 20 dp left / 16 dp below the status bar
- feature tray: 48 x 96 dp, 12 dp in from the top-right, `#80404040` fill, `#66606060`
  hairline, 16 dp radius (`lenshvc_k2_rounded_corner_background`, verbatim)
- shutter: **68 dp** ring, 6 dp stroke
- mode carousel: 46 dp band, 12 sp uppercase, +1.2 tracking, white selected / `#B3B3B3`
  otherwise, 8 dp item padding + 4 dp gaps
- filmstrip: **86 x 82 dp** tiles butted together, full bleed, 24 dp above the ring

Verified on the M34 (1080 x 2340 @ 450 dpi): ring `[445,1885][634,2074]` vs the original's
`[444,1878][635,2069]`; carousel glyphs `[166,2129][260,2152]` vs `[.., 2127..2151]`.
Everything lands inside 2.5 dp.

Three things the earlier build got wrong and this one fixes: the preview used to bleed under
the system bars, the document outline had a blur glow (Lens draws a crisp 2 dp orange line),
and the app auto-rotated (Lens is portrait-locked — the rotation was also invalidating every
measured coordinate).

Multi-page capture now lives in the session: shoot → crop → append page → repeat, filmstrip
tapping into review. `ReviewScreen` takes `pages`, saves each page to the gallery and exports
one PDF. Capture modes drive real tone presets (SCAN → none, WHITEBOARD → b&w, BUSINESS CARD
→ enhance) rather than being decorative labels.

Verified end to end on device: two pages captured, filmstrip shows both, review reports
"1 of 2", export writes a **2-page PDF** (`/Count 2`, 595 pt wide) and My Scans shows the PDF
tile with the "Exported PDF" snackbar.

Also fixed while verifying: the FileProvider only declared `files-path`, but scans live in
`app_flutter`, so "open in viewer" always failed. Added `root-path`; the system resolver now
opens the exported PDF.

### P2.5 — PDF writer ✅

`PdfDocument` Flate-compressed the raw bitmaps: **12 MB for two pages**. The pages were
already finished JPEGs, so the writer now emits the PDF itself and embeds each page as a
`DCTDecode` image XObject (hand-written catalog, page tree, content streams and xref; the
SOF marker supplies the frame size, so the pixels are never decoded).

| | `PdfDocument` | hand-written |
|---|---|---|
| 2 pages | 12.0 MB | **3.2 MB** |
| image encoding | Flate, raw RGB | DCTDecode, the rendered JPEG |
| further generations | 1 (re-encode) | 0 |

Each page keeps its own aspect (`/MediaBox` 595 x 578 and 595 x 691 for the test pair).
Verified by opening the export in Files by Google: both pages render, upright, full bleed.

### P3 — crop stage ✅

Rebuilt `adjust_screen.dart` against `lens-state4.png` and `crop_fragment_k2.xml`. The
original splits the stage three ways: the view holder (image + quad), a 96 dp
`lenshvc_crop_carousel_container` band, and a `cropscreen_bottombar` holding the hero.

| element | measured | shipped |
|---|---|---|
| feature tray | 102 × 146 dp, 8 dp right inset, parent-centred | 102 × 148 dp, 8 dp, centred |
| tray rows | 48 dp, label right-aligned 14 sp + 24 dp icon | same |
| top band | `black_30`, 15 dp padding + 48 dp target | 63 dp, glyph at 26/64 dp |
| filmstrip slot | 52 × 68 dp incl. 2 dp border, 12 dp gaps | same |
| "Crop document" | 14 sp, glyphs `[409,1703][672,1739]` | `[404,1712][676,1748]` |
| hero | 40 dp, 16 dp margins, `[45,2058][1034,2172]` | identical bounds |

Verified on device, all with screenshots in `.rea/shots/`:

- **Drag** moves the nearest corner; the quad repaints crisply.
- **Rotate** turns the preview 90° CW *and* re-orders the quad corners, so the native
  warp writes a rotated page (baked page checked in review).
- **Reset** restores the detected quad and clears the turn.
- **Retake** and the back arrow pop without committing.
- The dashed tile commits the page and re-shoots in one tap; the filmstrip then shows
  earlier session pages to the left of the centred current page.
- **Review and Edit** bakes the crop and lands on the review stage (`1 of 2` verified).

Tone preview: `colorMatrixFor()` mirrors `filterFor()` including Android's
`postConcat` order (contrast ∘ saturation). WHITEBOARD preview vs its baked page:
161/157/160/159 vs 167/159/159/162 — identical within JPEG noise.

One deviation: tiles are a fixed 52 × 68 with `BoxFit.cover` rather than the original's
aspect-fitted border (its sample page happened to be 45.5 dp wide). Fixed slots keep the
row centred without measuring every page.

### D1 - detection moved onto a model ✅

`edge_detector.dart` and its test are deleted. Detection is M-LSD 320 tiny fp16
(1,279,472 B, Apache-2.0) through `tflite_flutter`, with the reference `pred_squares`
post-processing ported to `document_detector.dart` and unit tested (8 cases, incl. a
skewed page recovered to within 6 px).

| | |
|---|---|
| model I/O on device | `1x320x320x4 float32` in, `1x160x160x4` map, 200 points |
| per-frame segments | 46-48 |
| release APK | **42,286,537 B** (was 52,914,359: x86_64 pruned, runtime + model added) |
| `package:image` | no longer used by the app (test-only) |

Verified live on the M34: the outline snaps to a receipt held at the frame edge and to a door
panel in perspective; a blank wall yields no quad. Build notes (Kotlin `jvmTarget` pin,
`packaging.jniLibs.excludes`) are in `findings.md`.

### P4 — review & edit ✅ `f8decb4`

Rebuilt `review_screen.dart` against `ui-edit.xml`, `postcapture_collection_view_k2.xml` and
`lens-state5.png`. The stage is **black**, not white as the earlier draft assumed; only the
packaging sheet is white.

| element | measured (`ui-edit.xml`) | shipped |
|---|---|---|
| top bar | 48 dp, back target at 12 dp | same |
| "Options" | ink `[897,131][1031,166]`, flush to the edge | `[897,131][1031,166]` |
| page inset | 16 dp | 16 dp |
| feature tray | `[910,879][1046,1423]` | `[912,~880][1046,~1410]` |
| action row | `[34,1827][1046,1990]` | 58 dp, labels on the measured baselines |
| Finish pill | `[56,2024][1024,2137]` | `[57,2025][1022,2136]` |
| options sheet top | 1755 (160 dp above the window bottom) | **1755** |

Edits are state, not pixels: `_Page` carries `bytes`, `filter` and `turns`, the pager previews
them with `ColorFiltered` + `RotatedBox`, and one new bridge method
(`NativeImageKit.transform` → `Bitmap.createBitmap(Matrix)` + `ColorMatrixColorFilter`, one
decode/encode) bakes them at save time. Nothing is re-encoded per tap, so tone switching costs
zero generations.

Real behaviour behind every affordance: Crop re-enters the crop stage, Rotate cycles quarter
turns, Delete drops a page (disabled at one), More opens the Options sheet, Filters picks one of
the four presets with a live preview, Reorder drags the pages into a new order, Add hands the
baked pages back to the capture session and resumes shooting, Finish saves the image(s) to the
gallery and/or one multi-page PDF.

Verified on the M34, screenshots in `.rea/shots/`:

- `p4-g.png` stage chrome, `p4-j.png` / `p4-k.png` options sheet (peek exactly 1755 px)
- `p4-m.png` filter chooser, `p4-o.png` rotate (landscape page, still greyscale)
- `p4-t.png` "Saved to Gallery · PDF: …" with both a JPEG and a PDF tile
- `p4-z.png` two-page session with Reorder/Delete enabled, `p5-a/b.png` reorder drag
- `p5-d.png` "Saved 2 pages" with both pages toned

One deviation: the filter chooser opens at 240 dp instead of the sheet's 160 dp peek. Four 16 sp
rows do not fit in 160 dp, and hiding half a chooser is worse than a taller sheet.

### P4.1 — saving corrections ✅

- **the name now reaches the file.** `saveImage` wrote `scan_<microseconds>.jpg` and kept the
  title only in the DB. Files are now `<title>.jpg` (uniquified `save (2).jpg`), which is also
  the name the gallery copy gets — the device shows `save.jpg` in MediaStore after a rename.
- **the PDF is a real export.** It goes to `Download/Scan/` through `MediaStore.Downloads`
  instead of app storage; the device shows `save.pdf` in a folder any file manager can open.

### P4.3 — one tile per save target ✅ `(this commit)`

P4.1 also stopped recording PDFs at all, which was wrong: the original gives a PDF save its own
list entry. Restored, so each target is a record of its own —

| ticked | My Scans | on disk |
|---|---|---|
| Image | JPEG tile | app copy + gallery copy |
| PDF | PDF tile (badge) | app copy (opens via FileProvider) + `Download/Scan` copy |
| both | two tiles | both of the above |

`writePdf` now writes the same byte array to `recordPath` (app storage, the tile) and to
`MediaStore.Downloads` (the export) in one call, so nothing is re-encoded. Verified on the M34:
"save" with both ticked gave a JPEG tile and a PDF tile plus `save.pdf` (376,884 B), and the PDF
tile raised the system PDF chooser; "pdfonly" with only PDF ticked gave exactly one PDF tile plus
`pdfonly.pdf` (1,052,312 B). Screenshots: `.rea/shots/p8-c.png`, `p8-d.png`, `p8-i.png`.

### P4.2 — steady outline + corner loupe ✅ `(this commit)`

- **`QuadSmoother`** filters the detector's frame-by-frame answers: a candidate must repeat for
  two frames before it is believed, and the drawn quad eases toward it at 40 %/frame. Alternating
  candidates now hold the outline still instead of hopping; brief misses no longer blink it.
  8 unit tests, including the exact alternation case.
- **Corner loupe** in the crop stage: `RawMagnifier`, 80 dp circle, 2 dp white ring, 2x, 24 dp
  above the finger, clamped to the stage. All sizes come from `lenshvc_crop_magnifier_*`; it
  magnifies the page, quad and grip in place, so the corner you are placing is what you see.

Sizes: **42,631,265 B** (+344,728 vs the D1 baseline, still 10.3 MB under the 52,914,359 budget).

### P5 — motion + device pass ✅ `(this commit)`

- **One hero button.** The crop stage's "Review and Edit" and the review stage's "Finish" are the
  same 40 dp accent pill again: `lib/design/lens_hero_button.dart` owns the fill, the busy
  spinner, the press-scale (0.98, 120 ms) and the disabled state, so the two stages cannot drift.
- **The mode carousel eases.** Selection changes cross-fade weight and colour over
  `LensMotion.fast` (`AnimatedDefaultTextStyle`) instead of snapping — the carousel is the stage's
  main type cue, so it carries the state change.
- **The integration scripts are real again.** `integration_test/app_flow_test.dart` now drives
  the shipped UI (capture button → shutter → "Review and Edit" → "Finish") and asserts what
  landed in the database. Both cases pass on the M34:

  ```
  FLOW image: +1 rows, newest=Scan Oct 26, 2026 9:03 AM image Scan Oct 26, 2026 9:03 AM.jpg
  FLOW pdf:   pdf:Scan Oct 26, 2026 9:03 AM.pdf, image:Scan Oct 26, 2026 9:03 AM (2).jpg
  ```

**On "60 fps":** not verified numerically, and this ROM cannot verify it. `dumpsys gfxinfo` reports
**0 frames** for the app (Flutter presents on its own `SurfaceView`, so HWUI has nothing to count)
and `dumpsys SurfaceFlinger --latency <layer>` returns only the 16.67 ms interval with an empty
frame buffer. A `watchPerformance` harness was written and run under `flutter drive --profile`;
it measured nothing useful — the second stage of the run never reached review — so it was deleted
rather than left in the tree as a broken tool. What *is* verified is the functional device pass
above plus the detector's own cost from D1 (~15-20 analysed frames per second in an isolate). If a
frame-rate number is required, the honest route is Android Studio's profiler or a Perfetto trace
with `frame_timeline` — both outside what this shell can drive.

### P6 — auto capture, page chip, corner guard ✅ `(this commit)`

- **Auto capture**, grounded in `capture_fragment_controls_k2.xml` (48 dp toggle container, 24 dp
  icon, 4 dp padding) and the `lenshvc_auto_capture_*` copy. The shot fires when the drawn quad
  drifts < 0.6 % of the diagonal per frame for 900 ms, so it only triggers on a page that is
  actually holding still. Hint pill ("Looking for a document" / "Document found" / "Hold steady"
  + the 1 dp progress line) sits above the filmstrip; the toggle is in More options (default
  on) rather than in the top bar, because a third tray slot would move chrome P2 verified to
  2.5 dp.
- **Page chip** in review (`1/2`), from `lenshvc_CollectionViewPageNumber_container_*`:
  min 37 × 28 dp, 4 dp radius, `#B3303030`, 12 sp white.
- **Corner guard.** `DocumentQuad.isUsable` (convex + no edge under 15 % of the longest) is
  checked during the drag *and* before baking, so a corner can no longer be dragged into a
  bow-tie that bakes a mostly-white page.

Verified on the M34: the app shot the doorway by itself and landed on the crop stage
(`pa-b.png`); dragging a corner onto its neighbour stopped at the last usable outline
(`pa-c.png`); a two-page session showed the chip (`pa-d.png`). Both integration flows still pass
after turning auto capture off through the new toggle, which also proves the toggle.

Sizes: **42,811,709 B** (+525,172 vs the D1 baseline, still 10.1 MB under the 52,914,359 budget).

### P7 — the scan menu names the file's location ✅ `(this commit)`

`dialog_options_recent_items.xml` ends its menu with `fragment_recent_items_info_parent`: a 46 dp
band, `info_recent_files` `#E5E5E5`, caption `#595959`, info glyph + 16 dp + one line of text, hint
"Location of the file". Ours shows the same band under Open / Share / Rename / Delete:

- image → `Phone Storage > Pictures > Scan` (the album `Gal` writes to)
- pdf → `Phone Storage > Download > Scan` (the `MediaStore.Downloads` publish)

It names the shared copy on purpose: the app's own record lives in `app_flutter/scans`, which no
file manager shows.

Sizes: **42,828,153 B** (+541,616 vs the D1 baseline, still 10.1 MB under the 52,914,359 budget).

### P8 — the folders are also a source of scans ✅ `(this commit)`

The original lists files dropped into `Pictures/Office Lens` and deletes by **ownership**: an
imported file leaves the list but stays on disk, a scan the app saved is deleted from its folder
too. `scan` now does both.

- **Indexer.** `ScanImageKit.listShared()` queries `Pictures/Scan` and
  `Download/Scan` through MediaStore (legacy directories below Q), returning name, mime,
  modified time and a 240 px preview for images.
- **No duplicates.** Every published copy's content URI is stored on the row
  (`scans.shared_uri`, schema v2), so the indexer skips this app's own exports; rows saved before
  that column existed are matched to their album copy by name, ignoring the punctuation and
  ` (n)` suffix MediaStore adds. Dismissing an imported file is *screen state*, not a row — the
  original forgets it as soon as you navigate away, so there is nothing to persist.
- **Deletes follow ownership.** Owned → record + private files + the published copy by URI.
  Imported → dismissed from the list only, the file stays. The imported menu is Open / Remove from
  My Scans; the location band names the folder it was found in.
- **`gal` is gone.** Images are published by `ScanImageKit.publishImage` through
  `MediaStore.Images` (same `IS_PENDING` publish as PDFs) because we need the URI back; that drops
  a plugin, its permission dance and the `hasAccess` messaging.
- Permission: `READ_MEDIA_IMAGES` (13+) / `READ_EXTERNAL_STORAGE` (≤32), requested on
  pull-to-refresh only, and the whole index step is capped at 8 s so it can never hold the list.

Verified on the M34: a file pushed into the album appears as its own tile (`pd-a.png`); removing it
leaves the file in place (`pd-c.png`); deleting an app-saved scan removes its gallery copy
(`pd-h.png`). `flutter test` = 45 tests.

Sizes: **42,921,309 B** (+634,772 vs the D1 baseline, still 10.0 MB under the 52,914,359 budget).

### Next

Nothing outstanding for P0–P8.
