# Lens Lite

A Flutter document scanner modelled on Microsoft Lens (`../lens.apk`), rebuilt
around the flow it is known for: **capture → adjust edges → save as image or PDF →
tracked scan history**. Edge detection, gallery saving and the crop step are
first-class; there are no cloud or office-suite integrations.

## Flow

1. **My Scans** (`lib/screens/history_screen.dart`) — every capture is listed with a
   thumbnail, type, timestamp, and open/share/rename/delete actions.
2. **Camera** (`lib/screens/camera_screen.dart`) — CameraX preview through the
   `camera` plugin, flash cycling (off/auto/on), lens switch, and live document
   detection: frames are analysed off the UI thread and the detected outline dims
   everything outside it.
3. **Crop** (`lib/screens/adjust_screen.dart`) — detected corners are pre-filled and
   draggable; *Done* applies a perspective rectification, *Full image* keeps the
   frame untouched, *Retake* confirms first.
4. **Review** (`lib/screens/review_screen.dart`) — name the scan, then *Save to
   gallery* (Android MediaStore, album "Lens Lite") or *Export PDF*; both return to
   My Scans with the new entry.

## Implementation notes

- `lib/services/edge_detector.dart` — pure-Dart detector: Otsu threshold → largest
  document-shaped region → convex hull → RDP simplification → four-corner quad. No
  model downloads. Inputs are downscaled to 240 px for analysis.
- `lib/services/edge_detection_worker.dart` — one long-lived isolate for detection
  (no per-frame isolate spawn), fed with `TransferableTypedData`.
- `lib/services/document_image_ops.dart` — decode/orient/preview/crop on background
  isolates, bounded to 2048 px so a 12 MP capture cannot exhaust the process heap.
- `lib/data/scan_repository.dart` — sqflite persistence; files live under
  `ApplicationDocumentsDirectory/scans`.

## Build and test

```bash
flutter pub get
flutter analyze                     # no issues
flutter test                        # 11 unit/widget tests
flutter test integration_test/app_flow_test.dart -d <device-id>   # on-device flow
flutter build apk --release
```

The integration tests drive the real widget tree on a connected handset: preview
must become visible, the crop step must reach review, and saving must record a row
in history. The camera probe (`integration_test/camera_probe_test.dart`) reports
each camera API step for hardware diagnostics.

`compileSdk`/`targetSdk` are pinned to 37 in `android/app/build.gradle.kts`
(`permission_handler` also requires compiling against 37); `minSdk` follows Flutter
(24). `RECORD_AUDIO` is explicitly removed from the merged manifest — the app never
records audio.
