import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'edge_detector.dart';
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

/// Decodes the capture once on the native side, detects the page on a small
/// RGBA buffer, and returns corners in full-resolution coordinates.
///
/// Nothing here decodes a multi-megabyte JPEG in Dart: the detector receives at
/// most a 480 px RGBA buffer, so detection cost is independent of the sensor.
Future<AdjustPreview?> prepareAdjustPreview(Uint8List jpeg) async {
  final capture = await NativeImageKit.analyze(jpeg);

  final small = img.Image.fromBytes(
    width: capture.detectWidth,
    height: capture.detectHeight,
    bytes: capture.rgba.buffer,
    order: img.ChannelOrder.rgba,
  );

  final detected =
      EdgeDetector.detectInImage(small) ??
      EdgeDetector.fullFrame(capture.detectWidth, capture.detectHeight);

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

/// Builds a [DocumentQuad] from the flat eight-value corner list.
DocumentQuad quadFromCorners(List<double> corners) => DocumentQuad(
  topLeft: math.Point(corners[0], corners[1]),
  topRight: math.Point(corners[2], corners[3]),
  bottomRight: math.Point(corners[4], corners[5]),
  bottomLeft: math.Point(corners[6], corners[7]),
);

/// Flattens a [DocumentQuad] back to the eight-value corner list.
List<double> cornersFromQuad(DocumentQuad quad) => <double>[
  quad.topLeft.x,
  quad.topLeft.y,
  quad.topRight.x,
  quad.topRight.y,
  quad.bottomRight.x,
  quad.bottomRight.y,
  quad.bottomLeft.x,
  quad.bottomLeft.y,
];
