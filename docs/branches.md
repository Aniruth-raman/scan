# Branches

What each branch in this repo is, what happened to it, and where the evidence lives.

Every branch also carries its own `docs/findings.md`. That file is the dated log of the work done on
that branch, including the measurements that decided each step, so it is the place to read when a
choice here looks arbitrary.

This index lives on `master`, the default branch.

| branch | status | in one line |
|---|---|---|
| `master` | shipped as `v1.0.0-msld` | offline scanner: bundled M-LSD detector, live outline, crop seeded from it, automatic cleanup |
| `mlkit-scanner` | shipped as `v1.0.0-mlkit` | the same app with Google's ML Kit Document Scanner doing the capture |
| `docaligner` | experiment, stopped | M-LSD replaced by a corner-heatmap model; it cannot tell a page from the frame it fills |
| `segmentation` | experiment, stopped | a self-trained MobileNetV2-UNet page segmenter, strong on its own dataset, weak on real pages |
| `lens-reproduction` | experiment, mined for parts | reproduction of Lens's tone/encode/package stages; where the cleanup and crop seeding came from |

## `master` - the offline scanner (shipped)

- **Detection:** M-LSD 512 large, bundled as `assets/models/document_edges.tflite` (3.1 MB,
  Apache-2.0). Line segments are fitted to a quad, which is drawn live over the preview and fires the
  shutter when the page holds still.
- **Crop:** the crop screen starts from the outline that was on screen, mapped onto the still, so the
  corners you lined up and the corners being cropped cannot disagree.
- **Tone:** every cropped page is enhanced automatically (grey-world white balance plus a 2-98%
  level stretch), the open equivalent of Lens's `CleanupImage`.
- **Known limit:** M-LSD's outline is loose when the page fills the frame, so the live outline
  overshoots; the crop stage's own detection on the bright still is what usually lands the page.
- **Release:** `v1.0.0-msld`, APK 44,555,203 B.

## `mlkit-scanner` - Google's scanner (shipped)

- **Detection and crop:** none of ours. Google's ML Kit Document Scanner owns the viewfinder, edge
  detection, crop, rotation and filters, and runs them inside Google Play services. The app ships no
  model and asks for no camera permission.
- **What is left in the app:** the scan list, review (rotate, reorder, delete, add pages, rename) and
  the JPEG/PDF export. The capture screen, the crop screen, the detector, the worker and the model
  were deleted along with their tests.
- **Worth knowing:** the release build used to fail on start with a `NullPointerException` because R8
  rewrote the component registrar ML Kit loads by reflection. `android/app/proguard-rules.pro` keeps
  `com.google.mlkit.**` and the scanner internals.
- **Known limit:** the scanner needs Google Play services (the module downloads on first use), the
  API is still Beta, and there is no per-frame corner API, so this branch has no live outline.
- **Release:** `v1.0.0-mlkit`, APK 32,949,670 B.

## `docaligner` - corner heatmaps (stopped)

Replaced M-LSD with DocAligner's LCNet100 corner-heatmap model (4.8 MB TFLite, converted from ONNX
with the BiFPN `Einsum` lowered by hand). Corners were accurate on a page with a visible margin, and
it carries the crop-screen fix that makes the 63 dp top band hit-transparent (later ported to
`master`).

It failed on the case that matters: a page that fills the view. The model needs the page to sit
*inside* the frame, so the branch pads the input with a 32 px near-black border - which turns the
frame into a bright rectangle on a dark surround, and the model returns the frame's four corners at
0.8-0.94 confidence. That is the "full-screen quad". Padding with mirrored pixels instead removed the
fake page and the detection with it.

Read: `docs/findings.md` on this branch, the sections about the margin and the pad.

## `segmentation` - self-trained page segmenter (stopped)

A UNet + MobileNetV2 page segmenter trained on SmartDoc 2015 with `tools/segmentation` (the tooling
was itself removed on later branches). On its own validation split: Dice 0.988, corner error 7.5 px,
0/100 missed. On a real page it segments about a quarter of it, because SmartDoc sheets occupy around
15% of the frame and a phone held over a book fills the frame instead.

That split also taught the useful part: the live feed was luma-only (34.7 px corner error versus
8.1 px in colour), point-sampled and flat, so the model saw a page it could not recognise. Area
averaging plus a percentile stretch fixed the input; the model still could not handle the framing.

Read: `docs/findings.md` on `lens-reproduction`, which inherits this line, for the colour, tone and
framing measurements.

## `lens-reproduction` - the Lens pipeline study (kept for parts)

Reproduces the stages Lens runs between capture and a saved page: tone, encode, packaging, DPI and
PDF geometry, plus the contract of which stage owns what. It also carries the segmentation
integration, the crop seeding fix (`cornersFromOutline`) and the input-padding experiment.

Two things written here are now shipped on `master`:

- `applyCleanup` (grey-world white balance plus percentile stretch), the substitute for Lens's opaque
  `CleanupImage`.
- `cornersFromOutline`, the mapping that seeds the crop from the live outline.

Read: `docs/findings.md` and `docs/pipeline.md` on this branch for the Lens comparison.
