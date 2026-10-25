import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'edge_detector.dart';

/// Decoded preview of a captured photo plus the corners to start from.
class AdjustPreview {
  const AdjustPreview({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.corners,
  });

  /// Display-oriented JPEG used for the on-screen preview.
  final Uint8List jpeg;
  final int width;
  final int height;

  /// Eight values: x/y for top-left, top-right, bottom-right, bottom-left.
  final List<double> corners;
}

/// Builds the adjust preview on a background isolate.
///
/// The closure is created here, in a top-level function, so it captures only
/// its arguments. A closure created inside a widget method would capture the
/// enclosing `this` (the `State`), which cannot be sent to another isolate.
Future<AdjustPreview?> prepareAdjustPreview(Uint8List jpeg) =>
    Isolate.run(() => _buildPreview(jpeg));

/// Perspective-crops [jpeg] to [corners] on a background isolate.
Future<Uint8List?> cropJpegToCorners(Uint8List jpeg, List<double> corners) =>
    Isolate.run(() => _crop(jpeg, corners));

/// Longest edge used for on-device image work.
///
/// Phone captures are 12 MP or larger; decoding, straightening and re-encoding
/// several full-resolution buffers at once runs the process out of memory, so
/// every step works on a bounded copy instead. 2048 px is far more than a
/// document scan needs.
const int maxWorkingDimension = 2048;

img.Image _limitToWorkingSize(img.Image image) {
  final longest = math.max(image.width, image.height);
  if (longest <= maxWorkingDimension) return image;
  final scale = maxWorkingDimension / longest;
  return img.copyResize(
    image,
    width: (image.width * scale).round(),
    height: (image.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
}

AdjustPreview? _buildPreview(Uint8List jpeg) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) return null;
  final baked = _limitToWorkingSize(img.bakeOrientation(decoded));
  final detected =
      EdgeDetector.detectInImage(baked) ?? EdgeDetector.fullFrame(baked.width, baked.height);
  return AdjustPreview(
    jpeg: Uint8List.fromList(img.encodeJpg(baked, quality: 90)),
    width: baked.width,
    height: baked.height,
    corners: <double>[
      detected.topLeft.x,
      detected.topLeft.y,
      detected.topRight.x,
      detected.topRight.y,
      detected.bottomRight.x,
      detected.bottomRight.y,
      detected.bottomLeft.x,
      detected.bottomLeft.y,
    ],
  );
}

Uint8List? _crop(Uint8List jpeg, List<double> corners) {
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) return null;
  final quad = DocumentQuad(
    topLeft: math.Point(corners[0], corners[1]),
    topRight: math.Point(corners[2], corners[3]),
    bottomRight: math.Point(corners[4], corners[5]),
    bottomLeft: math.Point(corners[6], corners[7]),
  );
  final out = EdgeDetector.cropToQuad(decoded, quad);
  return Uint8List.fromList(img.encodeJpg(out, quality: 95));
}
