import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'document_detection_worker.dart';
import 'document_detector.dart';
import 'native_image_kit.dart';

/// Decoded preview of a captured page plus the corners to start from.
class AdjustPreview {
  const AdjustPreview({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.corners,
  });

  /// Display-oriented JPEG, bounded by the native preview edge. This is only
  /// ever used for painting on screen.
  final Uint8List jpeg;

  /// Dimensions of the *full-resolution* capture. [corners] are expressed in
  /// this coordinate space so the crop is applied at capture resolution.
  final int width;
  final int height;

  /// Eight values: x/y for top-left, top-right, bottom-right, bottom-left.
  final List<double> corners;
}

/// A rectified, tone-mapped page ready to save.
class RenderedPage {
  const RenderedPage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// Decodes the capture once on the native side and returns the corners the crop
/// stage should start from.
///
/// When [normalizedCorners] is given - the live outline the user saw, in 0..1 of
/// the preview frame - those are the starting corners, mapped onto the capture's
/// own resolution. That is what makes the crop begin exactly where the outline
/// was, instead of at a fresh detection that may disagree with it. Detection is
/// the fallback, and is also used when the preview and the capture disagree about
/// aspect ratio, because then the outline cannot be mapped by proportion alone.
Future<AdjustPreview?> prepareAdjustPreview(
  Uint8List jpeg, {
  List<double>? normalizedCorners,
  Size? frameSize,
}) async {
  final capture = await NativeImageKit.analyze(jpeg);

  final corners = cornersFromOutline(
    normalizedCorners,
    frameSize,
    capture.fullWidth,
    capture.fullHeight,
  );
  if (corners != null) {
    return AdjustPreview(
      jpeg: capture.previewJpeg,
      width: capture.fullWidth,
      height: capture.fullHeight,
      corners: corners,
    );
  }

  // The model runs in its own isolate; a miss falls back to the full frame so
  // the crop stage always has a draggable quad.
  final detected =
      await DocumentDetectionWorker.instance.detectRgba(
        capture.rgba,
        width: capture.detectWidth,
        height: capture.detectHeight,
      ) ??
      DocumentQuad.fullFrame(capture.detectWidth, capture.detectHeight);

  // Detector coordinates -> full-resolution coordinates.
  final scaleX = capture.fullWidth / capture.detectWidth;
  final scaleY = capture.fullHeight / capture.detectHeight;

  double toFullX(double value) =>
      (value * scaleX).clamp(0.0, capture.fullWidth - 1.0);
  double toFullY(double value) =>
      (value * scaleY).clamp(0.0, capture.fullHeight - 1.0);

  return AdjustPreview(
    jpeg: capture.previewJpeg,
    width: capture.fullWidth,
    height: capture.fullHeight,
    corners: <double>[
      toFullX(detected.topLeft.x),
      toFullY(detected.topLeft.y),
      toFullX(detected.topRight.x),
      toFullY(detected.topRight.y),
      toFullX(detected.bottomRight.x),
      toFullY(detected.bottomRight.y),
      toFullX(detected.bottomLeft.x),
      toFullY(detected.bottomLeft.y),
    ],
  );
}

/// Maps a 0..1 outline from the preview frame onto the capture, or returns null
/// when the outline is absent.
///
/// The mapping mirrors how the outline is painted: `BoxFit.cover` of the
/// analysed frame into the preview, inverted. When the capture and the preview
/// share an aspect ratio that is a plain scale; when they do not, the offsets
/// keep the outline on the same part of the scene instead of stretching it.
List<double>? cornersFromOutline(
  List<double>? normalized,
  Size? frameSize,
  int fullWidth,
  int fullHeight,
) {
  if (normalized == null || normalized.length != 8) return null;
  if (frameSize == null || frameSize.width <= 0 || frameSize.height <= 0) {
    return null;
  }
  final scale = math.max(
    fullWidth / frameSize.width,
    fullHeight / frameSize.height,
  );
  final dx = (fullWidth - frameSize.width * scale) / 2;
  final dy = (fullHeight - frameSize.height * scale) / 2;

  final corners = <double>[];
  for (var i = 0; i < 8; i += 2) {
    corners
      ..add(
        ((normalized[i] * frameSize.width) * scale + dx).clamp(
          0.0,
          fullWidth - 1.0,
        ),
      )
      ..add(
        ((normalized[i + 1] * frameSize.height) * scale + dy).clamp(
          0.0,
          fullHeight - 1.0,
        ),
      );
  }
  return corners;
}

/// Rectifies [corners] at capture resolution and applies [filter] in one pass.
///
/// The source is always the original capture rather than the preview, so the
/// saved page keeps every pixel the camera recorded.
Future<RenderedPage> renderPage(
  Uint8List original, {
  required List<double> corners,
  required int fullWidth,
  required int fullHeight,
  ScanFilter filter = ScanFilter.none,
  int quality = 95,
}) async {
  final page = await NativeImageKit.warp(
    original,
    corners: corners,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    filter: filter,
    quality: quality,
  );
  return RenderedPage(
    bytes: page.bytes,
    width: page.width,
    height: page.height,
  );
}

/// Convenience wrapper for callers that only need the encoded bytes.
Future<Uint8List?> cropJpegToCorners(
  Uint8List original,
  List<double> corners, {
  required int fullWidth,
  required int fullHeight,
  ScanFilter filter = ScanFilter.none,
}) async {
  final page = await renderPage(
    original,
    corners: corners,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    filter: filter,
  );
  return page.bytes;
}
