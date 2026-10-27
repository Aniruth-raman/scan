# Scan

A document scanner for Android: point the camera at a page, it finds the page, you adjust the
corners, and it saves a JPEG or a PDF — no cloud, no account, nothing leaves the device.

Flutter UI over a single Kotlin bridge (`android/app/src/main/kotlin/com/aniruth/scan/ScanImageKit.kt`)
that does the capture-side decoding, the perspective warp, the image filters and the PDF writer.

## Build

```powershell
flutter pub get
flutter build apk --release   # needs ANDROID_HOME set
```

`flutter analyze` is clean and `flutter test` covers the detector, the quad smoother, the exporter
and the review screen. The on-device flows live in `integration_test/` (they need a camera, so they
run against a real device, not a host).

## How it fits together

| | |
|---|---|
| `lib/screens/` | capture, crop, review/edit, the scan list, the viewer |
| `lib/services/document_detector.dart` | page-corner detection, M-LSD 320 via `tflite_flutter` |
| `lib/services/native_image_kit.dart` | the Dart side of the one MethodChannel (`scan/image`) |
| `lib/design/` | tokens, theme, the shared controls — one flat blue accent, no dark mode |
| `android/.../ScanImageKit.kt` | `BitmapFactory`/`ImageDecoder`, `setPolyToPoly`, `ColorMatrix`, JPEG-in-PDF |

The detector is a bundled model rather than a hand-written edge pipeline: ML Kit has no
per-frame corner API, and its Document Scanner is an Activity flow that would own the viewfinder.
The model is M-LSD 320, Apache-2.0 — see `assets/models/LICENSE-mlsd.txt`.

## Licence

No licence file yet, so all rights reserved by default. Add one before anyone should reuse this.
