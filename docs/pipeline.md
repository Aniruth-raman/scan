# The scan pipeline: what Lens does, what is ours, what must be replaced

Purpose: keep **one pipeline** and swap implementations behind it. Every stage below has a
fixed contract (input -> output) and an explicit provenance label, so a proprietary stage can be
replaced without touching the stages around it.

Provenance labels used throughout:

| label | meaning | may ship? |
|---|---|---|
| `PLATFORM` | Android framework / CameraX / MediaStore / Canvas / ExifInterface | yes |
| `OSS` | third-party code or data with a permissive licence (Apache-2.0, MIT, CC BY 4.0) | yes, with attribution |
| `ALGORITHM` | published, non-proprietary maths (Sauvola, unsharp mask, homography, CLAHE) | yes, reimplemented by us |
| `PROPRIETARY` | Microsoft code, weights, or opaque native behaviour | **no - must be replaced** |
| `OURS` | written for `scan` | yes |

Evidence IDs refer to `docs/findings.md` and the REA ledger.

---

## The pipeline

```
S0 capture -> S1 decode/orient -> S2 detect -> S3 gate -> S4 crop
   -> S5 render -> S6 cleanup -> S7 encode -> S8 package
```

Lens and `scan` run these in this order today. The interesting part is that **S4 and S5 are one
pass** in both apps: every Lens filter shader calls `getPerspectiveMappedTexture(...)`, so the
homography and the colour work happen in a single draw, and the page is encoded once
(`ev_8d27eb2e...`). `scan` already does the same thing in `ScanImageKit.warp`.

### S0 - capture

| | |
|---|---|
| Lens | CameraX. Separate 4:3 and 16:9 resolution lists, a `Resolution` dialog showing `%1$.1f MP (%2$d x %3$d)`, and a per-identity preference (`CameraResolution`, `ev_337f702d...`) |
| contract | a JPEG (or YUV frame for live detection) + an orientation |
| `scan` | `camera` plugin, `ResolutionPreset.max`, 4:3 default; no user choice |
| provenance | `PLATFORM` (CameraX) + `OURS` (choice UI) |
| gap | no resolution control; sensor pixels are discarded later by the 4096 decode cap |

### S1 - decode + orient

| | |
|---|---|
| Lens | `ImageUtils.getScaledBitmap(..., SizeConstraint, ...)`, EXIF rotation, `decodeFile(Gravity.CENTER)` for the work bitmaps (`ev_8f01aa75...`) |
| contract | oriented bitmap at working resolution + the true capture size |
| `scan` | `ScanImageKit.decodeOriented(bytes, MAX_DECODE_EDGE = 4096)`, full EXIF cases |
| provenance | `PLATFORM` (BitmapFactory + ExifInterface) |
| note | Lens caps via `DEFAULT_MAX_BITMAP_SIZE`; `scan` caps every stage at 4096. Both are "cap", different numbers. |

### S2 - detect (live + still)

| | |
|---|---|
| Lens | two detectors behind `ScanComponent`: native `GetCroppingQuad` (classic lines, up to N quads, `SetCenter`, `subRectangleMargin`) and a DNN mask (`QuadModel.TEAMS_MNV2_WB` = `lens/models/mnv2_ep42_wb_quant.ort`). `shouldUseDNNQuad()` needs model loaded + feature gate + `isPerfCriteriaMet()`; `isGpuSupported`/`isNNAPISupported` tracked. Temporal: `detectSceneChange`, `getSimilarQuadIndex`, `getClosestQuadIfAvailable`. `ev_e6a23796...`, `ev_03b52331...`, `ev_266559ea...`, `ev_d603...` |
| contract | 0..N quads in frame coordinates + a per-quad score |
| `scan` | one MobileNetV2-UNet segmenter (`assets/models/document_mask.tflite`) in an isolate, one quad, `quad_smoother` for stability |
| provenance | **`PROPRIETARY`** weights + inference wrapper (`com.microsoft.scan.ScanNative`) in Lens; `OSS` (SmartDoc 2015, CC BY 4.0) + `OURS` in `scan` |
| gap | no N-quad output, no perf-based detector switch, no classic fallback. Model is 26.5 MB vs Lens 342 KB - same architecture, wrong size |

### S3 - presence gate

| | |
|---|---|
| Lens | `ILensDocClassifierComponent`, 3-class `triclass_doc_classifier.ort` (and a TFLite twin `clf_model.tflite`), plus the "Not a scan?" nudge (`lenshvc_modeless_not_scan_mode_nudge_button`). `ev_fafa6a43...`, `ev_60559...` |
| contract | `isDocument` + a class label, used to skip processing and to offer the nudge |
| `scan` | none. A missed quad simply means "full frame" |
| provenance | **`PROPRIETARY`** weights |
| gap | a non-document capture is silently processed as a page; no corrective affordance |

### S4 - crop

| | |
|---|---|
| Lens | homography from `CropData` (`getHomographyMatrix`) -> `GPUImagePerspectiveFilter`; output size from native `GetCroppedImageSize`, i.e. the quad's own edge lengths in **source pixels**, no fixed cap (`ev_c53133eb...`, `ev_8bb2fb12...`) |
| contract | source bitmap + quad + output size -> rectified bitmap |
| `scan` | `Matrix.setPolyToPoly` on CPU, output = max opposite edges, clamped to 4096 (`ScanImageKit.warp`) |
| provenance | `ALGORITHM` (homography) + `PLATFORM` (Canvas) |
| gap | CPU instead of GPU; 4096 cap vs no cap |

### S5 - render (process mode -> filter chain)

| | |
|---|---|
| Lens | `ProcessModeUtils.getImageFilters(mode)` -> `GPUImageFilterApplier`; each shader fuses the perspective sample, so crop + tone is one pass. Available: perspective, colour matrix + intensity, tone-curve LUT, grayscale, separable blur, arbitrary kernel, unsharp, Sauvola (3 variants), segmentation mask, grain, vignette, and the photo set. `ev_04ad2ccc...`, `ev_8b108008...` |
| contract | rectified bitmap + mode + rotation -> filtered bitmap |
| `scan` | one 4x5 `ColorMatrix` per preset (none / enhance / grayscale / black & white) |
| provenance | shader **source** is Microsoft's (**`PROPRIETARY`** as text); the **algorithms** are `ALGORITHM`; the gpuimage library is `OSS` Apache-2.0 |
| gap | no adaptive threshold, no unsharp, no tone curve, no white balance, no whiteboard mode |

The one stage where exact numbers are already recovered, so a faithful reimplementation is
possible without their code - the Sauvola pair (`classes5.dex`):

```
pass 1 (per axis):  n = 41, step = 5.0 / (n * 100) of the image dimension
                    out.rgb = (luma, mean(luma), sqrt(mean(luma^2)))
pass 2:             k = 0.2, R = 0.5, darkenFactor = 0.5
                    threshold = mean * (1 + k * ((s / R) - 1))
                    out = white                   if pixel >= threshold
                        = pixel * darkenFactor    otherwise
```

That is textbook Sauvola with a 41-sample window spanning 5 % of the frame, a half-grey floor
instead of black, and the same constants for the grayscale-colour variant.

### S6 - cleanup

| | |
|---|---|
| Lens | `ILensScanComponent.cleanUpImage(bitmap, ScanFilter)` -> `PhotoProcessor.cleanUpImage` -> JNI `OfficeLensProductivity.CleanupImage`; `Document -> 2`, `Whiteboard -> 3` (`ev_c30d2e9a...`, `ev_2ea0d669...`, `ev_faf56950...`) |
| contract | bitmap + Document/Whiteboard -> bitmap, in place |
| `scan` | nothing on the default path |
| provenance | **`PROPRIETARY`** - algorithm is inside `libpixsdk`/`libOfficeLens.so`, only its effect is observable |
| gap | the whole stage. This is the single biggest output-quality difference |

### S7 - encode

| | |
|---|---|
| Lens | `FileUtils.writeBitmapToFileAndSync(..., (int)(imageCompression * 100), ...)`; default `MediaCompression.low = 0.75` -> **JPEG q75**; `MediaCompression` none 1.0 / low .75 / medium .4 / high .3; `ExifUtils.addExifMetaDataForProcessedImageIfEnabled` writes EXIF/DPI; `ImageDPI` default `high = -1` (keep native), low 150, medium 220 (`ev_a922829b...`, `ev_0674a6e4...`, `ev_c349f4d2...`, `ev_f19baadc...`) |
| contract | bitmap + quality + dpi -> JPEG bytes with EXIF |
| `scan` | fixed q95, no EXIF written |
| provenance | `PLATFORM` (Bitmap.compress + ExifInterface) |
| gap | no quality setting, no DPI, no EXIF |

### S8 - package

| | |
|---|---|
| Lens | `PdfQuality{High, Medium, Low}` + `ImagesToPDFConverterConfig` + `ImageDPI` (`ev_f0464d94...`, `ev_bbacc976...`); also OneDrive/Word/PowerPoint targets, which we do not copy |
| contract | pages (+ quality, dpi) -> PDF + shared copies |
| `scan` | `DCTDecode` passthrough, `A4_WIDTH_PT = 595` for every page, no DPI |
| provenance | `OURS` (PDF writer) + `PLATFORM` (MediaStore) |
| gap | page geometry is resolution-blind; no quality choice |

---

## Proprietary inventory (must not ship)

| artefact | what it is | replacement path |
|---|---|---|
| `assets/lens/models/mnv2_ep42_wb_quant.ort` (342 KB) | Microsoft-trained page-mask segmenter, int8 | already replaced by our UNet+MobileNetV2 TFLite (CC BY 4.0 dataset). **Needs int8 quantisation: 26.5 MB -> target <= 5 MB** |
| `assets/lens/models/triclass_doc_classifier.ort` (204 KB) | Microsoft document-present classifier | train a 3-class head on SmartDoc + our own negatives, or use an on-device label API (new dependency - needs approval) |
| `assets/clf_model.tflite` (401 KB) | TFLite twin of the classifier | same as above |
| `libpixsdk.OfficeLensProductivity.so` / `libOfficeLens.so` `CleanupImage`, `GetCroppingQuad`, `GetCroppedImageSize`, `GetLines` | opaque native cleanup + classic line detector | `S6`: our own white-balance + CLAHE + unsharp, or Sauvola for B&W; `S2` classic fallback: none (segmentation covers it) |
| inline GLSL in `classes5.dex` | Microsoft's shader text | reimplement the published formulas with equivalent constants; do not copy the source |
| `PostCaptureCollectionView` / packaging flow | Office packaging UI | not in scope |

Not proprietary, safe to reuse as-is: CameraX, MediaStore, Canvas, BitmapFactory,
ExifInterface, PrintManager (`PLATFORM`); the gpuimage library and its generic shaders
(`OSS`, Apache-2.0); Sauvola / Niblack / unsharp / homography / tone curve (`ALGORITHM`);
SmartDoc 2015 (`CC BY 4.0`), `segmentation_models_pytorch` and M-LSD (`Apache-2.0`).

---

## Reproduction status

| stage | contract in `scan` | reproduces Lens behaviour? | blocked on |
|---|---|---|---|
| S0 | capture only | partially - no resolution choice | UI + plugin preset mapping |
| S1 | yes | yes | - |
| S2 | yes | architecture yes, weights/size no | int8 model export, N-quad scoring |
| S3 | **missing** | no | a non-proprietary classifier |
| S4 | yes | yes (CPU, 4096 cap) | GPU path is optional |
| S5 | 1 of 7 modes | no | implementing the filter set |
| S6 | **missing** | no | writing the substitute cleanup |
| S7 | fixed q95, no EXIF | no | profile plumbing |
| S8 | fixed A4 width | no | profile plumbing |

### Swap order (one stage per change, pipeline untouched)

1. **S7 + S8 together** - quality/DPI/EXIF and DPI-aware PDF pages. No pixel-path change, no new
   dependency, testable with the existing exporter test.
2. **S5** - implement the scan-mode palette (`none`, `document`, `whiteboard`, `blackAndWhite`,
   `grayscale`, `sauvolaColor`, `sbcAdjust`) with the constants above; keep one entry point so
   modes are data, not branches at the call site.
3. **S6** - the cleanup substitute (white balance + contrast stretch + unsharp). Isolated function;
   swapping it later must not change S5 or S7.
4. **S3** - presence gate. **Needs a decision**: bundle a small trained classifier, or add an
   on-device labelling dependency. Gate this one explicitly.
5. **S2** - quantise our segmenter to int8 and add the N-quad score so the crop stage can pick.
6. **S0** - capture resolution choice, mapped onto `camera`'s presets (the plugin cannot request an
   arbitrary `Size`, so this is a divergence, not a copy).

Acceptance for every swap: same stage inputs/outputs, `flutter analyze` clean, `flutter test`
green, release APK measured against `74,580,524 B`, and one device run of capture -> crop -> save
-> PDF.
