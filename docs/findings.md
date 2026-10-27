?# Reverse engineering `lens.apk` (REA, evidence-backed)

Target: `lens.apk` — SHA-256 `6757a4271865443356435f6521d500770aef88b14aa89209045aaeb8d43cb55a`
Tooling: REA 6.7.0 CLI, JADX headless MCP 0.7.1, apktool 3.0.3.

> Kept in the repo on purpose: this is where every measurement in the app comes from. It holds
> notes, measurements and a handful of quoted UI strings — no Microsoft code, resources, assets or
> binaries are included, and `lens.apk` itself is not distributed with this project.

## Tooling blockers that were fixed

REA reported `capability_unavailable` for every Android operation. Causes and fixes:

| Blocker | Fix applied |
|---|---|
| `REA_JADX_MCP_JAR` unset — the required JAR was on disk but nothing pointed at it | Set to `C:\Users\aniruth\.local\share\rea\android\jadx-headless-mcp-0.7.1-all.jar` in `.agents/mcp.json` (`env`) and as a user environment variable |
| `rea` CLI only existed inside an ephemeral `npx` cache (doctor: `installations.state: multiple`) | `npm i -g rea-agents@6.7.0` → stable `rea` on PATH |
| apktool missing (`REA_APKTOOL_COMMAND`) — resource/string decoding was unavailable | Installed apktool 3.0.3 + wrapper at `~/.local/share/rea/android/apktool.bat`, exported `REA_APKTOOL_COMMAND` |

After the fixes `rea doctor` reports `healthy: true` with the `jadx` provider configured **and** available.

## Evidence

### Package identity — `ev_28ddc82faae06fbe480af52359695301f2477ad76e76dd472b336a6cc0488e64`

- `com.microsoft.office.officelens` 16.0.18526.20136 (Microsoft Lens / Office Lens)
- `minSdk 24`, `targetSdk 34`, 21,105 classes, 2,559 resources
- Permissions of interest: `CAMERA`, `READ_MEDIA_IMAGES`, `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`

### Capture and analysis stack — `ev_b474b77103426f27bca0484081cab5af0c9662df55876c5c6cc280d8f45f47f8`

`search-android-classes lens.apk camera` → 401 classes, all `androidx.camera.*`
(CameraX `camera2` implementation, `ExperimentalAnalyzer`). ML Kit (`com.google.mlkit.*`)
is present for on-device analysis. The first-party analysis pipeline is namespaced:
`com.microsoft.office.lens.lenscommon.api.ILensAnalyzerComponent`,
`…work.LensMediaItemAnalyzerSetting`. Application classes are R8-minified, so name
searches for `cropper` / `lexis` / `documentdetect` return nothing — the reliable
evidence is the library inventory plus decoded resources.

### Flow copy and states — `ev_9ba97f42bb4616e598b09d9e27faf4ff10cba52a7993c1cffc38b30c131d1cc7`

`decode-android-resources` → 1,860 strings, 93 locales. Flow-relevant originals:

| Key | Value |
|---|---|
| `lenshvc_camera_access_error_title` | Camera Service error |
| `camera_initialization_error` | Unable to initiate camera, please close other camera apps and try again… |
| `button_capture` / `content_description_capture` | New Capture / Capture |
| `lenshvc_auto_capture_looking_for_content` | Looking for a %1$s |
| `lenshvc_auto_capture_in_progress` | Capturing… Hold steady |
| `button_crop`, `content_description_crop_done` | Crop, Done |
| `lenshvc_crop_retake_dialog_message` | Going back will delete this photo. Do you want to retake it? |
| `content_description_retake` / `button_retake` | Retake image / Retake |
| `button_add_image`, `lenshvc_crop_add_image_label` | Take more, Add |
| `button_save` / `content_description_save` | Save / Save image |
| `document_status_gallery_completed`, `…_pdf_completed` | Tap to open |
| `lenshvc_content_description_camera_facing_rear` / `_front` | Rear / Front |
| `flash_mode_off/auto/on/torch` | Off / Auto / On / Torch |

## What was mimicked in `scan`

- **Capture → crop → save → history** flow kept exactly, with the original's copy:
  the crop step is titled *Crop*, with a *Retake* confirmation using the original
  sentence, and a primary *Done* action; *Full image* skips the perspective crop.
- **Camera failure state** uses the original's wording ("Camera Service error",
  close other camera apps) instead of a raw platform exception, plus retry.
- **Detection affordance** mirrors the original's two states: *Looking for a document*
  while searching, *Document detected* with a dimmed overlay and corner accents.
- **Saving** returns to My Scans (the list where earlier scans are tracked), matching
  the original's "Tap to open" recent-files behaviour.

Deliberately not cloned: OCR/table extraction, OneDrive/OneNote/Word/PowerPoint targets,
multi-page bulk mode, auto-capture trigger, cloud/MDM pieces.

## Does ML Kit replace `edge_detector.dart`? — checked, no

Question: could the hand-written detector be replaced by ML Kit, as the repo rules prefer?

**Evidence 1 — `lens.apk` has no ML Kit document scanner.**
Class inventory `ev_c5c5bfff3da1b8d987f33dc6ebbee10311c4047ee6569f5fc87e9c4beb0994f0`
(21,105 top-level classes): zero `com.google.mlkit.vision.documentscanner.*` and zero
`com.google.android.gms.mlkit.documentscanning.*` / `GmsDocumentScanning`. Present ML Kit
modules are only `vision.text` (Text Recognition v2), `vision.label` (image labeling),
`vision.common`, `common`, plus `libtensorflowlite_jni_gms_client.so`.

**Evidence 2 — the original detects documents with its own bundled models.**
Direct APK zip read (not REA): `assets/lens/models/mnv2_ep42_wb_quant.ort` (342,016 B) and
`assets/lens/models/triclass_doc_classifier.ort` (204,064 B), plus `assets/clf_model.tflite`
(400,997 B, image labeling). No ONNX Runtime Java classes appear in `ev_c5c5bfff…`, so the
`.ort` graphs are consumed below the Java layer. Conclusion: Microsoft Lens runs a
first-party/mobile-net detector, not a Google scanning API.

**Evidence 3 — ML Kit's Document Scanner is a whole-screen flow, not an image API.**
Official docs, page updated 2026-10-23 (`developers.google.com/ml-kit/vision/doc-scanner/android`):
`play-services-mlkit-document-scanner:16.0.0`, ~300 KB app-side, "models, scanning logic and
UI flow are dynamically downloaded by Google Play services", minSdk 21, 1.7 GB RAM. The only
entry point is `GmsDocumentScanning.getStartScanIntent(activity)`; results arrive as JPEG/PDF
URIs from `GmsDocumentScanningResult`. There is no per-frame or per-image corner/quad API.

**Consequence for `scan`.** The detector feeds two things ML Kit cannot serve:
`camera_screen.dart` `_quad` → `_QuadOutlinePainter` (live orange outline + the
"Looking for a document"/"Document detected" states), and `document_image_ops.dart:60`
`EdgeDetector.detectInImage` seeding the Adjust screen's starting corners. Adopting ML Kit
would mean replacing the entire capture→crop UI with Google's scanner activity, not swapping
an implementation. That is a product decision, not a refactor.

**Disposition (pending user choice):** keep `edge_detector.dart` under the
"last resort — no platform API exists" clause of `AGENTS.md` §1, or delete the capture/crop
screens in favour of the ML Kit flow.

## Document detection is a model now, not hand-written geometry (2026-10-25)

The hand-written `edge_detector.dart` (find the brightest large region -> outline -> quad) was
deleted: it boxed the bright wall on scenes with no document and collapsed on shadows and
low-contrast paper. Detection is now a bundled TFLite model.

**Model choice. Every size below was fetched, not estimated.**

| candidate | format | size | licence | verdict |
|---|---|---|---|---|
| M-LSD 320 tiny fp16 (`navervision/mlsd`) | TFLite, official repo | 1,279,472 B | Apache-2.0 | **chosen** |
| M-LSD 320/512 large fp16 | TFLite | 3,115,104 B | Apache-2.0 | 2.4x the size, no need |
| DocAligner LCNet100 (`DocsaidLab`) | ONNX only | 4.8 MB | Apache-2.0 | best-known corners, but needs ONNX Runtime (~15 MB) or an onnx2tf conversion |
| FairScan DeepLabV3+ (`pynicolas`) | TFLite | ~3 MB | **GPL-3.0** | rejected: would force the whole app to GPL |

Model I/O read back on device (`flutter` log): `input 1x320x320x4 float32, map 1x160x160x4,
200 points`, which is exactly what the reference `pred_lines` / `pred_squares` code consumes.
That post-processing is ported in `lib/services/document_detector.dart`; the reference also
scores overlap and side-length balance, but both weights are 0.0, so only corner balance, area
and distance from the centre can change the winner.

**Runtime cost, measured from the published AARs.** `tflite_flutter 0.12.1` ships no `.so`; it
depends on `com.google.ai.edge.litert:litert:1.4.0` (+ `litert-gpu`, which we exclude).
Per ABI: `libtensorflowlite_jni.so` = 4.12 MB arm64 / 2.73 MB v7a / 5.77 MB x86_64,
`libtensorflowlite_gpu_jni.so` = 2.39 / 1.47 / 2.52 MB.

**Build changes.** Release targets arm64 + v7a only. `ndk.abiFilters` does **not** remove
AAR-provided natives; `packaging.jniLibs.excludes` does. `tflite_flutter` hard-codes Java 11
while its Kotlin compiles to the JDK default (17 here, 25 unaligned), so the root build pins
every module's Kotlin `jvmTarget` to 17 and `kotlin.jvm.target.validation.mode=warning` lets the
plugin's own 11/17 split through. Android caps app bytecode at Java 17, so a newer JDK does not
remove that pin.

| build | bytes |
|---|---|
| before | 52,914,359 |
| after: runtime + 1.28 MB model, x86_64 pruned | **42,286,537** (-10.6 MB) |

**Device results.** 46-48 segments per frame. `.rea/shots/live1.png` and `crop3.png`: the live
outline snaps onto a paper receipt held at the frame edge and onto a door panel in perspective.
A wall with no document produces no quad at all, which is the behaviour the old detector lacked.

## Review & Edit stage is black, and here is its geometry (2026-10-26)

Evidence: `res/layout/postcapture_collection_view_k2.xml`, `res/values/dimens.xml`,
`res/values/colors.xml`, `res/values/styles.xml`, `res/drawable/lenshvc_k2_feature_tray_background.xml`,
plus the live hierarchy in `.rea/shots/ui-edit.xml` and the screenshot `lens-state5.png`.

**Correction to the earlier plan.** `plan.md` §3 said the editor was white. It is not:
`postCaptureCollectionViewRoot` sets `android:background="@color/lenshvc_black"`, the bottom bar
is `postCapture_bottomBar_color_coherence` = `#000000`, and `lens-state5.png` is black chrome with
white glyphs. Only the packaging sheet over it is white. Everything below is what the shipped
build actually does.

| element | source | measured (px @ 2.8125 px/dp) |
|---|---|---|
| top bar | `guideline_top_margin`, `lenshvc_touch_target_height` | 48 dp; back target 48 dp at 12 dp (`lenshvc_oc_image_button_padding`) |
| "Options" | `lenshvc_pill_button_text_size` 14 sp, `lenshvc_postcapture_close_text` `#D6D6D6`, 16 dp horizontal / 5.5 dp vertical padding | flush to the end edge, ink `[897,131][1031,166]` |
| pager | 16 dp page inset (`[45,…][1035,…]`), vertically centred | top 231, page box `[45,523][1035,1508]` |
| feature tray | `topFeatureTrayContainer` + `feature_tray_end_margin` 12 dp + `feature_tray_width` 48 dp × 4 × `feature_tray_item_height` 48 dp, constrained top and bottom (centred) | `[910,879][1046,1423]` = 48 × 193 dp |
| tray item | `lenshvc_k2_feature_tray_item_layout`: 12 dp padding, 14 sp label, 12 dp gap, 24 dp icon | icon-only at 48 dp wide — the label collapses, unlike the 102 dp crop tray |
| tray plate | `lenshvc_k2_feature_tray_background`: `#CC171717`, 1 dp `#66606060`, radius 16 dp | sampled 65 over a 235 page ⇒ 80 % coverage, i.e. `#CC` not the capture tray's `#80404040` |
| action row | `bottom_bar_padding` 12 dp, three 120 dp cells, `lenshvc_bottom_bar_icon_margin_top` 10 dp / `_bottom` 8 dp, 12 sp label, 24 dp icon | row `[34,1827][1046,1990]` = 58 dp; label ink `1946..1979` |
| action colours | theme `lenshvc_bottom_bar_icon_text_color` | enabled label `#D6D6D6`, icon `#ADADAD`; disabled (single page) `#5C5C5C` — all sampled |
| Finish | `finish_btn_container` 48 dp + 8 dp margins, `lenshvc_k2_hero_btn_height` 40 dp, `lenshvc_bottom_bar_hero_item_background` (theme fill, radius 8 dp) | pill `[56,2024][1024,2137]`, 24 dp check + 8 dp + 14 sp label, black on `#D83B01` |
| options sheet | `bottom_sheet_packaging_options.xml`, `lenshvc_drawer_handle`, `lenshvc_packaging_header_padding` 16 dp, `lenshvc_handoff_header_text_size` 12 sp | sheet top 1755 = 160 dp above the window bottom; handle 36 × 4 dp; header 20 sp; section bands `#F2F2F2`; rows 16 sp / 24 dp icon / 16 dp gap |
| checkboxes | `lensCheckableGroup` | accent fill + white tick when on, 2 dp accent outline when off (`lens-state6.png`) |

**Why "Reorder" was grey in the shot.** `ui-edit.xml` was captured with one page. `Reorder`'s
icon and label are `#5C5C5C` there and `#D6D6D6` with two pages — it is disabled, not styled
differently. Delete follows the same rule in `scan`.

**Platform note.** On the M34 (Android 16) Flutter reports `MediaQuery.padding.top` ≈ 28 dp
while Lens's window starts 34 dp below the screen edge. Bottom-anchored geometry therefore
matches to ≤ 1 dp (Finish pill `[57,2025][1022,2136]` vs `[56,2024][1024,2137]`), and everything
hung off the top bar sits ~6 dp higher than the original. This is the environment, not the
layout — do not "fix" it by adding paddings.

## Saving: the JPEG is the record, the PDF is a record *and* an export (2026-10-26)

Corrections after using the P4 build, all verified on the M34:

| symptom | cause | fix |
|---|---|---|
| the name typed into the sheet never reached the file - always `scan_<micros>.jpg` | `saveImage` built the path from `microsecondsSinceEpoch`; the title only went into the DB row | the path is now `ScanExporter.fileStem(title)` + extension, uniquified as `name (2).jpg` |
| the exported PDF never appeared in external storage | `writePdf` wrote into the app's private `app_flutter/scans` | the same bytes are written twice: an app-storage record (the tile) and a `MediaStore.Downloads` copy under `Download/Scan` (`IS_PENDING` publish). API 24-28 falls back to the public Downloads dir behind the legacy grant |

**Each save target is its own record, as in the original.** Image -> JPEG tile; PDF -> PDF tile;
both -> two tiles, one with the PDF badge. The PDF exists twice on disk by design, exactly like a
JPEG does (app copy for the list, gallery copy for the user): the app-storage copy is what the
tile opens through `FileProvider`, and `Download/Scan` is the copy a file manager sees.

> One detour worth recording: P4.1 first made the PDF *not* a record, on the reading that Lens
> keeps only the JPEG. Re-checking the original showed the opposite - a PDF save gets its own
> list entry - so the row was restored in P4.3. `ScanEntry.isPdf`, the badge and the `openFile`
> path were never removed, which made that a small revert.

Measured on the device: "save" with both targets produced `save.jpg` in the gallery, a JPEG tile
and a PDF tile, and `Download/Scan/save.pdf` (376,884 B); tapping the PDF tile raised the
system PDF chooser. "pdfonly" with only PDF ticked produced exactly one PDF tile and
`Download/Scan/pdfonly.pdf` (1,052,312 B).

`MediaStore` replaces characters it dislikes in `DISPLAY_NAME` - the default title lands as
`Scan Oct 26, 2026 5_46 AM.jpg` even though the app-side file keeps the colon - so `fileStem`
only strips what breaks a path or a file browser (`\ / * ? " < > |`), not `:` or `,`.

Also fixed while here: the rename dialog disposed its `TextEditingController` the moment
`showDialog` returned, while the dialog's exit animation was still rebuilding the field
("A TextEditingController was used after being disposed"). Both rename dialogs now use a
`TextFormField` that owns its own editing state.

## Live outline jitter and the corner loupe (2026-10-26)

### Why the outline hops

`DocumentDetector` answers each frame independently — no state, no score compared against the
last frame — so on a real desk two well-scoring candidates (the page and the desk edge, say) can
trade places every frame. Nothing in the model can be "tuned" for this: it is a filtering
problem, not a detection one.

**Fix: `lib/services/quad_smoother.dart`** (new, 8 unit tests). Two stages:

- *confirm* — a detection only becomes the target once two consecutive frames agree within 8 %
  of the frame diagonal. Two candidates that alternate never agree with themselves, so neither
  is adopted; the outline holds still.
- *follow* — the drawn quad eases toward the target 40 % per frame, so per-frame noise becomes a
  slow drift instead of a shake. A brief run of misses (5 frames) no longer blinks the outline
  away.

Corner order is re-aligned (cyclic shift) before comparing, so a quad reported from a different
starting corner does not look like a 300 px jump.

Device check: 12 captures 250 ms apart over a static scene — the outline was present in 11 and
consecutive captures agreed to the pixel while it held (`615/611` and `491/487/483` outline
pixels), changing only when a different candidate repeated. Before, the outline could change on
every frame.

### The loupe while dragging a corner

`crop_fragment_k2.xml` already ships one, and it is fully specified by resources:

| resource | value |
|---|---|
| `lenshvc_crop_magnifier` (`com.microsoft.office.lens.lenscommonactions.crop.CircleImageView`) | `lenshvc_crop_magnifier_diameter` = **80 dp**, `scaleType="matrix"`, `elevation 8 dp` |
| `lenshvc_crop_magnifier_boundary` | **2 dp** (the ring) |
| `lenshvc_crop_magnifier_offset_from_closest_edge_initial` | 44 dp |

It draws the *same page bitmap* through a matrix (`scaleType="matrix"`), i.e. a magnified view of
the content under the finger rather than a second widget tree. `scan` does that with
**Flutter's `RawMagnifier`** (`BackdropFilter` + `ImageFilter.matrix`): the page, the quad line
and the corner grip are the same pixels at 2x, no second decode, and the content under the finger
is what stays centred (`focalPointOffset = finger - centre`, derived from `_RenderMagnification`'s
matrix). The circle sits 24 dp above the finger and is clamped inside the stage so it never
leaves the screen.

The zoom factor is the one value not in the resources — 2x is our choice, noted as such.

## Auto capture, page chip, corner guard (2026-10-26)

### Auto capture

Resources: `capture_fragment_controls_k2.xml` puts a 48 dp container
(`lenshvc_vertical_menu_container_size`) at the top bar's end, holding a 24 dp icon
(`lenshvc_top_bar_icon_size`, `lenshvc_auto_capture_icon_padding` 4 dp) with
`lenshvc_auto_capture_on_icon`; the hint is a pill (`lenshvc_auto_capture_hint_message_padding`
12 dp, `…_corner_radius` 8 dp) and the hold before the shot is a 1 dp line
(`lenshvc_auto_capture_progress_thickness`). Copy: `…_auto_capture_looking_for_content`
("Looking for a %1$s"), `…_auto_capture_in_progress` ("Capturing. Hold steady"),
`…_auto_capture_no_content_found`, and `…_auto_capture_fre` confirms it is a **toggle**
("Turn Auto Capture ON to detect documents automatically").

`scan` runs the same idea off the smoother instead of a second detector pass:

- the shot fires when the **drawn** quad drifts less than 0.6 % of the frame diagonal per frame
  for **900 ms**, so the ease has to converge first and a moving hand keeps resetting the hold;
- only a usable quad counts (see the guard below), and never while the More sheet is open, while
  capturing, or on the front camera;
- the hint pill shows "Looking for a document" / "Document found" / "Hold steady" plus the 1 dp
  progress line, bottom-centre above the filmstrip;
- the toggle lives in **More options** (`SwitchListTile`, default on) rather than as a top-bar
  icon: the measured feature tray is 48 × 96 dp and adding a third slot would move chrome that
  P2 verified to 2.5 dp. Stated as a deliberate divergence.

### Page chip

`lenshvc_CollectionViewPageNumber`: `minWidth` 37 dp (`…_container_width`), 28 dp tall
(`lenshvc_viewpager_peak_size`), radius 4 dp (`…_container_radius`), background
`lenshvc_page_number_background` `#B3303030`, 12 sp white, 8 dp margins. `scan` shows it
centred in the review bar once a session has more than one page. The text format is ours — no
format string exists in the resources — so it reads `1/2`.

### The scan menu's location band
Evidence: `layout/dialog_options_recent_items.xml` — four 56 dp rows (16 dp padding, icon + 16 dp +
label), then `fragment_recent_items_info_parent`: **46 dp** tall, `@color/info_recent_files`
**#E5E5E5**, 16 dp side padding, an info glyph, 16 dp gap and a caption in
`@color/info_recent_files_caption` **#595959**. Its hint is `content_description_location_my_files`
("Location of the file"), and the path is composed from `pdf_local_storage` ("Phone Storage") +
`media_storage_location` ("Pictures") + the album, which is why the original reads
"Phone Storage > Pictures > Office Lens".

`scan` puts the same band under its menu, naming the copy the user can actually reach:

| kind | band |
|---|---|
| image | `Phone Storage > Pictures > Scan` (the gallery album `Gal` writes to) |
| pdf | `Phone Storage > Download > Scan` (the `MediaStore.Downloads` publish) |

The app's own record stays private, so this intentionally points at the shared copy rather than at
`app_flutter/scans`. If the gallery copy was refused at save time the band is optimistic — the
snackbar at save already said "Saved to My Scans" in that case.

### The corner that used to bake a white page

Dragging a corner across the opposite side makes the outline a bow-tie, and dragging two corners
together collapses an edge; in both cases `setPolyToPoly` maps most of the source outside the
page and the uncovered rest comes back white (`warp()` fills uncovered pixels white). The fix is
`DocumentQuad.isUsable`: convex winding (no collinear corners) and no edge shorter than 15 % of
the longest. It is enforced **in the drag** (the corner stops at the last usable outline) and
again before baking, so even a sliver from the model cannot be committed. Not a detector change —
it is a predicate on the quad.

## The folder is also a source of scans (2026-10-26)

Observed on the original: a file dropped into `Pictures/Office Lens` appears in its scan list, and
deletes follow **ownership** — an imported file disappears from the list but stays on disk, while a
scan the app saved is deleted from its folder as well. `scan` now does both.

**Storage model.** Every save still writes two copies: the private record (what the tile opens and
shares, in `app_flutter/scans`) and a published copy (`Pictures/Scan/<title>.jpg` or
`Download/Scan/<title>.pdf`). The published copy's **content URI is stored on the row**
(`scans.shared_uri`, schema v2), which is what makes the rest exact:

| | app-saved record | file found in a folder |
|---|---|---|
| how it is listed | the row | `MediaStore` query over both folders |
| appears once because | its `shared_uri` is skipped by the indexer | it has no row |
| delete | record + private copy + the published copy, by URI | **dismissed from the list only**; the file stays, and the dismissal is forgotten as soon as you leave the screen |
| menu | Open / Share / Rename / Delete | Open / Remove from My Scans |
| location band | the folder its export went to | the folder it was found in |

**Schema v2** adds `scans.shared_uri TEXT` with an `onUpgrade` `ALTER` (v3 only drops the
`hidden_media` table that a first attempt at this feature introduced). Existing rows keep
working: a row without `shared_uri` is matched to its album copy by file name.

That name match has to be loose, because MediaStore rewrites the name on the way in: it replaces
`:` with `_` and appends ` (1)` when a name is taken (`Scan Oct 26, 2026 10_32 PM (1).jpg`).
So both sides are compared as `[a-z0-9]` only, with any trailing ` (n)` removed.

**Dismissing an imported file is view state, not a database row.** The original forgets the
dismissal the moment you navigate away, and the file was never ours; a table would only preserve
something the user cannot see the point of. `scan` keeps the set in the screen's `State` and
clears it on resume, on pull-to-refresh and when returning from the camera.

**Permission.** The indexer needs to read media the app did not write: `READ_MEDIA_IMAGES` on
Android 13+, `READ_EXTERNAL_STORAGE` before that. Without it MediaStore only shows the app's own
files, which the indexer skips anyway — so the feature is invisible rather than broken. It is
requested on **pull-to-refresh** (the one moment the user is asking to look outside), never at
launch, and the whole index step is wrapped in an 8 s timeout so a wedged query can never hold the
list hostage.

**`gal` is gone.** The gallery copy is now published by `ScanImageKit.publishImage` through
`MediaStore.Images` (same `IS_PENDING` publish as the PDF), which is what returns the URI we need;
that removed a plugin, its permission dance and its `hasAccess` messaging path.

MediaStore quirks seen while verifying: it rewrites `:` to `_` in `DISPLAY_NAME` (so the album file
is `Scan Oct 26, 2026 10_46 PM.jpg` while the app copy keeps the colon); shell-inserted rows are
invisible to an app without the media grant; and a row inserted by hand can disappear again, so the
imported path was verified with a real pushed file plus a `MEDIA_SCANNER_SCAN_FILE` broadcast.

## The launcher mark is a page, not an aperture (2026-10-27)

The P9 shutter was measured, not guessed, and it was the wrong mark at the wrong size:

| | old | why it failed |
|---|---|---|
| white disc | r = 33 of the 108 dp canvas | on a circular mask **84%** of the icon is white (3421 of 4071 dp²): the blue survives only as scratches |
| blade gaps | 3.2 dp | 1.4 dp at a 48 dp launcher slot, 0.7 dp at 24 dp — it greys out |
| outer edge | the six blade cuts run through it | reads as a sawblade, not an aperture |
| concept | aperture = camera | the app crops pages; nothing in it takes a photo |

The replacement is one closed path: **a 40 × 54 dp page, 14 dp chamfer on the top-right corner
(45°), 3 dp corner radius, centred on the visible area.** One silhouette, nothing thinner than
3 dp, so it holds at 24 dp and survives being flattened to one tint.

**An adaptive foreground is drawn into the full 108 dp and only clipped to the inner 72 dp when
presented.** So the path is authored in 108-space (`x 34..74, y 27..81`), not scaled to the visible
area: a 72 viewport over a 108 dp canvas zooms the mark by 1.5 and it swallows the tile. That
mistake shipped to the M34 once and was caught in an App info screenshot.

**Two files because a themed icon carries no colour.** Themed icons use the *alpha* of the
monochrome layer only, so the foreground must stay a bare silhouette with no background fill;
hence `drawable/ic_launcher_foreground.xml` (white shape, 108 viewport) and its pre-26 twin
`mipmap-anydpi/ic_launcher.xml` (the same path translated by (-18, -18) into a 72 viewport that
fills the tile, plus the brand rect, so the page is the same 40 × 54 of 72).

**Safe-zone check.** The 66 dp circle is the only area every mask shape guarantees. The page's
sharpest corner sits 33.6 dp from centre (r 33), so a 72 dp circular mask clears it by 2.4 dp and
Material's squircle clears it comfortably ((20/36)⁴ + (27/36)⁴ = 0.41). The old disc, being a
circle of r 33, was inside by construction — that part it got right.

**`anydpi` outranks the density buckets.** The vector therefore supplies the icon below API 26 on
its own, and the ten `mipmap-*/ic_launcher*.png` files were deleted (55,334 B) along with the
unreferenced `mipmap-anydpi-v26/ic_launcher_round.xml` (347 B) and the five now-empty density
folders. `ic_launcher_round.*` was never reachable anyway: the manifest sets no
`android:roundIcon`. Release APK went 42,715,011 → **42,686,787 B**.

## Back to M-LSD, with the *large* model instead of the tiny one (2026-10-27)

The `document_scan` experiment (OpenCV, +40.5 MB) was reverted and the bundled M-LSD detector
restored — the branch the repo rules already bless for the live quad. On top of that, the model
was upgraded because the tiny 320 was the reason detection kept coming up empty:

| | before (D1) | now |
|---|---|---|
| model | `M-LSD_320_tiny_fp16.tflite` | `M-LSD_512_large_fp16.tflite` |
| input | 320×320×4 | 512×512×4 |
| output map | 160×160 | 256×256 |
| size | 1,279,472 B | 3,115,168 B |

Two accuracy wins over the tiny 320, both from the model itself rather than the post-processing:
the **large** backbone extracts edges the tiny one misses (the M-LSD paper scores the large family
a few sAP points higher), and the **512 input** keeps finer edge detail than the 320 downscale.
The 512's 256-px output map also lands on the post-processing's `_refSize = 512` exactly
(`512 / 256 = 2.0`), whereas the 320's 160-px map ran through a 3.2× scale, quantising segment
endpoints more coarsely. The detector reads input/map/point shapes from the model at load, so this
was a model-file swap with no code change.

Source: `navervision/mlsd` `tflite_models/M-LSD_512_large_fp16.tflite`, Apache-2.0 (same licence,
`assets/models/LICENSE-mlsd.txt`).

`flutter analyze` clean, `flutter test` 46/46. Release APK **44,522,435 B** — 28.67 MB under the
74,580,524 B `document_scan` baseline, back in line with the original ~42 MB budget (the extra
~1.8 MB is the larger model).

## What Lens's edge detection actually is: a MobileNetV2 segmenter (2026-10-27)

`lens.apk` bundles three on-device models, all referenced from the DEX (`classes4.dex` names both
`.ort` files, `classes5.dex` names the `.tflite`):

| file | size | input | output | what it is |
|---|---|---|---|---|
| `assets/lens/models/mnv2_ep42_wb_quant.ort` | 342,016 B | `N×256×256×3` f32 | `N×256×256×1` f32 | **document page segmenter** |
| `assets/lens/models/triclass_doc_classifier.ort` | 204,064 B | `1×3×256×256` f32 | `1×3` | 3-class gate (document present/type) |
| `assets/clf_model.tflite` | 400,997 B | `1×256×256×3` f32 | `1×3` | 3-class gate (document present/type) |

The segmenter graph is `QLinearConv` / `QLinearAdd` / `QLinearConcat` + `ResizeBilinear` + the
`convolution_output*_zero_point` tensors — i.e. an **int8-quantized MobileNetV2 encoder with a
bilinear-upsampling decoder**, emitting one 256×256 page mask per 256×256 RGB frame. It is a
**semantic-segmentation** detector, not line segments (M-LSD) or corner heatmaps (DocAligner).

That is the reason its edge detection feels better: a dense page mask is robust edge-to-edge, under
occlusion, and against busy backgrounds, and the quadrilateral is then read off the mask contour
(the code calls it `mnv2_ep42_wb_quant` — MobileNetV2, epoch 42; "wb" is a training/mode tag). The
two 3-class classifiers gate "is a document present", which is what our `DocumentQuad? == null`
fallback does without a classifier.

**Open-source equivalents** (the weights themselves are Microsoft's and not redistributable):

- **`ternaus/midv-500-models`** (MIT, Vladimir Iglovikov): UNet + ResNet34, binary document
  segmentation, trained on MIDV-500, weights released
  (`unet_resnet34_2020-05-19.zip`, 90.7 MB). The closest pre-trained open-source document
  segmenter. Preprocessing is ImageNet normalisation (mean 0.485/0.456/0.406, std 0.229/0.224/0.225).
- **MobileNetV2 + UNet via `segmentation_models_pytorch`** (Apache-2.0): the same architecture
  family as Lens's model, mobile-sized, but needs training on a document/page dataset. This is the
  path that matches Lens's footprint; `midv500models` above shows the full training recipe
  (Albumentations, 512 crop, ImageNet norm).
- `pynicolas/FairScan` is also a segmentation scanner but GPL-3.0, so it is not usable here.

**Pipeline to copy:** 256×256 RGB → int8 MobileNetV2/UNet segmenter → 256×256 mask → threshold →
largest contour → `minAreaRect`/`approxPolyDP` → 4 corners → existing `DocumentQuad`. Preprocessing
for the Lens graph could not be pinned down by probing (raw, `/255`, `[-1,1]` and ImageNet norm all
produced a near-empty mask on synthetic/out-of-distribution frames), so treat the exact normalisation
as unknown; the architecture, I/O and quantisation are established.

## Tried the only pre-trained OSS document segmenter — not viable (2026-10-27)

`ternaus/midv-500-models` (MIT) is the only ready-made open-source document segmentation model
found. It is **UNet + ResNet34**, `classes=1`, trained on MIDV-500 **ID documents**, ImageNet
normalisation. Converted it `ResNet34-UNet .pth → ONNX (torch.onnx, opset 16) → TFLite (onnx2tf)`:

| precision | TFLite size |
|---|---|
| float32 | 97,774,952 B |
| float16 | 48,922,304 B |
| dynamic-range int8 | 24,639,392 B |

Two blockers:

1. **Size.** Even int8 is 23.5 MB, roughly doubling the app (44.5 MB → ~68 MB). fp16 (46.7 MB) would
   blow the 74.5 MB budget outright.
2. **Domain.** It is ID-document-specific. On the test card it produced only a partial 0.3–0.6 band;
   on the real book page it lit only a left-edge sliver. It does not generalise to paper pages/books,
   which is what actually needs detecting.

Conclusion: there is no mobile-sized, general-document open-source segmentation model ready to drop
in. Lens's model is a MobileNetV2 segmenter trained on general documents; to match it the realistic
path is to **train a MobileNetV2-UNet (`segmentation_models_pytorch`, Apache-2.0) on a general
document-page dataset** (receipts, pages, books, cards), then convert to int8 TFLite (~2–5 MB) and
read corners off the mask contour. That is a training job, not a conversion job.

`flutter analyze`/tests unchanged (no code integrated; this branch only carries the investigation).

## How Lens actually turns a capture into a saved page (2026-10-27)

This is the end-to-end scan pipeline, read from the shipped DEX (`lenscommon*`,
`lensscan`, `lensquadmaskfinder`, `lenscommonactions` packages are **not** R8-renamed, so
these are real method bodies, not guesses).

| step | Lens | evidence |
|---|---|---|
| capture | CameraX; user-selectable resolution list (4:3 and 16:9 kept separately, MP shown as `%1$.1f MP (%2$d x %3$d)`) | `ev_337f702d…`, `ev_25709997…`, `lenshvc_resolution_format` |
| detect (classic) | `PhotoProcessor.getCroppingQuads` → JNI `OfficeLensProductivity.GetCroppingQuad(+SetCenter)`, returns up to N quads as 8 float arrays | `ev_049d536d…` |
| detect (DNN) | `ScanComponent.getDNNCroppingQuads` → `QuadMaskFinderComponent` → `QuadMaskFinder`/`RGB3PxQuadMaskFinder` → `QuadModel.TEAMS_MNV2_WB` = `lens/models/mnv2_ep42_wb_quant.ort` → `com.microsoft.scan.ScanNative` (JNI: `loadDNNModel`, `computeDNNQuad`, `getImageSegmentMaskArray`, `loadDocClassifier`, `loadImageSegmenationModels`, `loadCleanupModel`) | `ev_e6a23796…`, `ev_266559ea…`, `ev_60ff8291…`, `ev_70f9a217…`, `ev_714aad11…`, `ev_d39741ee…` |
| which detector | `shouldUseDNNQuad()` = model loaded **and** feature gate `useDNNQuadChangeGate` **and** `isPerfCriteriaMet()`; `isGpuSupported`/`isNNAPISupported` tracked on the component | `ev_03b52331…` |
| stability | `detectSceneChange`/`resetSceneChange`, `getSimilarQuadIndex`, `getClosestQuadIfAvailable`, viewport-restricted quads, point-must-lie-inside-quad | `ev_fafa6a43…` |
| crop | homography from `CropData` → `GPUImagePerspectiveFilter`, on GPU; output size from `getCroppedImageSize` (native) = the rectified quad size, i.e. crop pixels at source resolution, no fixed cap | `ev_8d27eb2e…`, `ev_c53133eb…`, `ev_8bb2fb12…` |
| enhance | `ProcessModeUtils.getImageFilters(mode)` → `GPUImageFilterApplier`; palette = Perspective, SegmentationMask, `Sauvola{Horizontal,Vertical,VerticalPassThroughColor}`, UnsharpMask, ColorControl, ToneCurve, OptimizedFilterGroup, GaussianBlur + photo filters | `ev_04ad2ccc…`, `ev_8b108008…`, `ev_2c7c1164…` |
| non-GPU cleanup | `ILensScanComponent.cleanUpImage(bitmap, ScanFilter)` → `PhotoProcessor.cleanUpImage` → JNI `OfficeLensProductivity.CleanupImage`; `getFilterType` maps `Document→2`, `Whiteboard→3` — runs on **every** processed page | `ev_c30d2e9a…`, `ev_2ea0d669…`, `ev_faf56950…` |
| modes | `ProcessMode` sealed hierarchy: `Scan{None, Document, Whiteboard, BlackAndWhite, GrayScale, SauvolaColor, SBCAdjust}`, `Photo{None, Auto, Mono, Lomoish, …}` | `ev_bc5e9cfc…` |
| encode | `FileUtils.writeBitmapToFileAndSync(bitmap, …, (int)(imageCompression * 100), …)` → **imageCompression is JPEG quality**; default `MediaCompression.low` = **0.75** → q75. `MediaCompression`: none 1.0 / low .75 / medium .4 / high .3 | `ev_a922829b…`, `ev_0674a6e4…`, `ev_a3982daf…` |
| DPI | default `ImageDPI.high` = **-1** (do not force a DPI); low = 150, medium = 220 | `ev_c349f4d2…`, `ev_f19baadc…` |
| metadata/export | `ExifUtils.addExifMetaDataForProcessedImageIfEnabled` writes EXIF/DPI back; PDF export carries `PdfQuality{High, Medium, Low}` and `ImagesToPDFConverterConfig` | `ev_a922829b…`, `ev_f0464d94…`, `ev_bbacc976…` |

Two corrections to the entry above ("What Lens's edge detection actually is"):

1. **The `.ort` file is named in DEX and executed through a JNI wrapper, not "below the Java
   layer" by an unknown runtime.** `QuadModel.<clinit>` hard-codes
   `lens/models/mnv2_ep42_wb_quant.ort` as the `TEAMS_MNV2_WB` model path and
   `com.microsoft.scan.ScanNative.loadDNNModel` loads it. No `libonnxruntime.so` and no ORT Java
   class ship in the APK, so "ONNX Runtime" is still **not** established — what is established is
   whose code owns the inference call.
2. **TFLite is a separate, Java-visible stack** (`com.example.lenstensorflowlitewrapper`,
   `org.tensorflow.lite.*`, `libtensorflowlite_jni_gms_client.so`, `assets/clf_model.tflite`).
   It is not the `.ort` path.

### Where `scan` diverges

| | Lens | `scan` |
|---|---|---|
| live detector | DNN segmenter + classic line detector, chosen by perf gate; multiple quads | single M-LSD 512, one quad, smoothed by `quad_smoother` |
| presence gate | 3-class doc classifier + "Not a scan?" nudge | none (null quad only) |
| crop | GPU perspective filter, output = quad size at source pixels | `Matrix.setPolyToPoly` on CPU, cap `MAX_OUTPUT_EDGE 4096`, white fill |
| enhancement | native `CleanupImage` on every page + Sauvola/unsharp/tone-curve palette per mode | 3 `ColorMatrix` presets, default **none** |
| modes | Document / Whiteboard / Business Card / Photo / Auto | Scan / Whiteboard / Business card, where whiteboard = global B&W matrix |
| JPEG quality | q75 default, per-identity preference | q95 fixed |
| DPI / EXIF | written into the file | not written (plain `Bitmap.compress`) |
| PDF | A4 + `PdfQuality` + `ImageDPI` | fixed `A4_WIDTH_PT = 595` for every page, page height from the image aspect |
| resolution | user picks MP; crop keeps source pixels | `ResolutionPreset.max`, decode capped at 4096 |

### Issues this comparison exposes in `scan` (no code changed yet)

1. **No cleanup on the default path.** Lens runs `CleanupImage` on every page; `scan`'s default
   filter is `none`, so the saved page is the raw crop. The `enhance` preset is a mild matrix and
   `blackAndWhite` is a global 1.7× contrast, not Sauvola — under uneven light it clips, where
   Lens's B&W/Grayscale are local adaptive thresholds.
2. **`Whiteboard` capture mode lies.** `_CaptureMode.whiteboard` maps to `ScanFilter.blackAndWhite`,
   so a whiteboard photo is saved as high-contrast greyscale. Lens's whiteboard is a colour-preserving
   native cleanup.
3. **PDF page geometry is resolution-blind.** `A4_WIDTH_PT = 595` regardless of pixel width: a
   900 px page prints at ~109 dpi and a 4000 px page at ~484 dpi, and no DPI is recorded. Lens has
   `ImageDPI` (150/220/native) and `PdfQuality` for exactly this.
4. **No EXIF/DPI on saved JPEGs**, so downstream OCR/print tools cannot tell a page's physical size.
5. **Re-crop is lossy and irreversible.** `review_screen._recrop` passes `_current.bytes` (the already
   warped, already encoded page) back into `AdjustScreen`, so a second crop can only cut more of the
   previous crop and costs another q95 generation. Lens keeps `OriginalImageInfo` and re-renders from
   the capture.
6. **Review edits add a generation.** Rotate/change-filter goes through `NativeImageKit.transform`,
   re-encoding q95; Lens applies review filters to the source and encodes once at save.
7. **Detection input is 480 px while the model wants 512**, so every still is resampled twice
   (480 → 512) before inference. Lens feeds `requiredImageWidth/Height` exactly into a reused bitmap.
8. **No resolution control** even though the camera is opened at `ResolutionPreset.max` and then
   clipped to 4096 — a 50 MP capture silently loses most of its pixels with no way to ask otherwise.

## The outline now seeds the crop (2026-10-28)

The gap: `camera_screen._capture()` never passed `_quad` to `AdjustScreen`, so the crop stage
re-detected the page from the still. Two different detections then disagreed about the same shot,
and the corners the user had lined up were not the corners being cropped.

Fix, in the pipeline's own terms:

| stage | before | now |
|---|---|---|
| shutter | `_quad` dropped | `_quad` + `_frameDisplaySize` read before the stream is paused |
| handoff | `AdjustScreen(originalJpeg)` only | `normalizedCorners` (0..1 of the analysed frame) + `frameSize` |
| crop seed | always re-detected | outline mapped onto the capture; detection only when there is no outline |

The mapping (`cornersFromOutline`) inverts the same `BoxFit.cover` geometry the outline is painted
with, so a preview/still aspect difference offsets the corners instead of stretching them. Tests
cover equal aspect, 4:3 preview against a 16:9 capture, malformed input, and clamping.

Verified on the M34 by driving the real flow over adb:

1. My Scans -> camera: live quad drawn, "Document found".
2. Shutter -> crop screen opens with the quad on the same page corners.
3. Adjust -> Review and Edit -> Options (title, Save as Image/PDF) -> Finish.
4. `Pictures/Scan/Scan Oct 28, 2026 12_26 AM.jpg` (275,597 B) and
   `Download/Scan/Scan Oct 28, 2026 12_26 AM.pdf` (276,168 B).
5. PDF geometry: `/MediaBox [0 0 365 367]` for a `1519 x 1526` page, i.e. `1519 * 72 / 300` —
   the S8 DPI sizing is live.

Note: Auto Capture was on, so one steady scene produced an automatic shot plus the manual one.
That is the feature working, and it is why the first test session held two pages.
