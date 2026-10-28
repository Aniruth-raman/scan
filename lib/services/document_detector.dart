import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A detected document outline: four corners in display pixel coordinates,
/// ordered clockwise from top-left.
class DocumentQuad {
  const DocumentQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  final math.Point<double> topLeft;
  final math.Point<double> topRight;
  final math.Point<double> bottomRight;
  final math.Point<double> bottomLeft;

  Iterable<math.Point<double>> get corners => [
    topLeft,
    topRight,
    bottomRight,
    bottomLeft,
  ];

  /// Scales the quad by [sx]/[sy], e.g. preview space to full resolution.
  DocumentQuad scale(double sx, double sy) => DocumentQuad(
    topLeft: math.Point(topLeft.x * sx, topLeft.y * sy),
    topRight: math.Point(topRight.x * sx, topRight.y * sy),
    bottomRight: math.Point(bottomRight.x * sx, bottomRight.y * sy),
    bottomLeft: math.Point(bottomLeft.x * sx, bottomLeft.y * sy),
  );

  /// The full frame, used when no document is detected.
  static DocumentQuad fullFrame(int width, int height) => DocumentQuad(
    topLeft: const math.Point(0, 0),
    topRight: math.Point(width - 1.0, 0),
    bottomRight: math.Point(width - 1.0, height - 1.0),
    bottomLeft: math.Point(0, height - 1.0),
  );

  /// Largest corner-to-corner distance to [other], in pixels.
  double distanceTo(DocumentQuad other) {
    final mine = corners.toList();
    final theirs = other.corners.toList();
    var worst = 0.0;
    for (var i = 0; i < 4; i++) {
      final dx = mine[i].x - theirs[i].x;
      final dy = mine[i].y - theirs[i].y;
      worst = math.max(worst, math.sqrt(dx * dx + dy * dy));
    }
    return worst;
  }

  /// True when the four corners still describe a page: convex, ordered, and not
  /// squashed into a sliver.
  bool get isUsable {
    final points = corners.toList();
    var winding = 0;
    for (var i = 0; i < 4; i++) {
      final a = points[i];
      final b = points[(i + 1) % 4];
      final c = points[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-6) return false;
      final turn = cross > 0 ? 1 : -1;
      if (winding == 0) {
        winding = turn;
      } else if (turn != winding) {
        return false;
      }
    }

    var shortest = double.infinity;
    var longest = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = points[i];
      final b = points[(i + 1) % 4];
      final length = math.sqrt(
        (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y),
      );
      shortest = math.min(shortest, length);
      longest = math.max(longest, length);
    }
    return longest > 0 && shortest / longest >= 0.15;
  }
}

/// Edge length of the model's square input, in pixels.
const int documentModelInputSize = 256;

/// Border, in model pixels, that the live frame is inset by on every side.
///
/// shortcut: the model was trained on sheets that fill about 15% of the frame
/// and it under-segments a page that fills the view (measured on a real frame:
/// it covered 24% of the page at full scale and 85% once the page was inset to
/// 0.55 of the input). Remove this when the model is retrained on full-frame
/// pages.
const int _liveInset = documentModelInputSize ~/ 5;

/// ImageNet normalisation, matching the training preprocessing.
const List<double> _imagenetMean = [0.485, 0.456, 0.406];
const List<double> _imagenetStd = [0.229, 0.224, 0.225];

/// Document detection with a MobileNetV2 page-segmentation model
/// (trained with `tools/segmentation`, same family as Lens's detector).
///
/// The model is a 256x256 RGB segmenter: it emits a 256x256 page mask. The
/// largest connected region is reduced to a quadrilateral (convex hull, then
/// the four most significant corners), which is the outline the app draws.
///
/// A frame with no confident page produces no mask, so nothing is returned and
/// the caller falls back to the full frame.
///
/// It was trained on colour photographs and chroma is much of what separates
/// white paper from a desk, so both surfaces feed it colour.
class DocumentDetector {
  DocumentDetector._(this._interpreter);

  /// A mask pixel at or above this (after sigmoid) is part of the page.
  static const double _threshold = 0.5;

  final Interpreter _interpreter;

  /// Loads the model. Throws when the graph does not have the expected
  /// fingerprint, so a bad asset fails loudly at startup rather than silently
  /// returning no detections.
  static DocumentDetector load(Uint8List modelBytes) {
    // One thread leaves 300-500 ms per frame on a mid-range phone; the live
    // outline needs it faster than that.
    final interpreter = Interpreter.fromBuffer(
      modelBytes,
      options: InterpreterOptions()..threads = 4,
    );

    final input = interpreter.getInputTensor(0);
    final inputShape = input.shape;
    if (inputShape.length != 4 ||
        inputShape[1] != documentModelInputSize ||
        inputShape[2] != documentModelInputSize ||
        inputShape[3] != 3) {
      interpreter.close();
      throw StateError(
        'Unexpected document model input ${inputShape.join('x')}',
      );
    }
    if (input.type != TensorType.float32) {
      interpreter.close();
      throw StateError('Document model expects ${input.type} input');
    }

    final output = interpreter.getOutputTensor(0);
    final outShape = output.shape;
    if (outShape.length != 4 || outShape[3] != 1) {
      interpreter.close();
      throw StateError(
        'Unexpected document model output ${outShape.join('x')}',
      );
    }

    debugPrint(
      'document model: input ${inputShape.join('x')} ${input.type.name}, '
      'mask ${outShape.join('x')}',
    );
    return DocumentDetector._(interpreter);
  }

  // --------------------------------------------------------------- surfaces --

  /// Detects a quad in a prepared model input, as produced by
  /// [prepareRgbaInput] or [prepareYuvInput].
  ///
  /// Corners come back in display coordinates, scaled to [displayWidth] x
  /// [displayHeight].
  DocumentQuad? detectPrepared(
    Float32List input, {
    required int displayWidth,
    required int displayHeight,
  }) {
    if (input.length != documentModelInputSize * documentModelInputSize * 3) {
      return null;
    }
    return _detect(input, displayWidth, displayHeight, inset: _liveInset);
  }

  /// Detects a quad in a display-oriented RGBA buffer, as returned by the
  /// native analyser. Coordinates are in buffer pixels.
  DocumentQuad? detectFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
  }) {
    if (width < 8 || height < 8 || rgba.length < width * height * 4) {
      return null;
    }
    return _detect(
      prepareRgbaInput(rgba, width: width, height: height),
      width,
      height,
    );
  }

  // ------------------------------------------------------------- inference ---

  DocumentQuad? _detect(
    Float32List input,
    int frameWidth,
    int frameHeight, {
    int inset = 0,
  }) {
    final inputTensor = _interpreter.getInputTensor(0);
    final bytes = Uint8List.view(
      input.buffer,
      input.offsetInBytes,
      input.lengthInBytes,
    );
    if (bytes.length != inputTensor.data.length) return null;
    inputTensor.data = bytes;
    _interpreter.invoke();

    final output = _interpreter.getOutputTensor(0).data;
    final logits = Float32List.view(
      output.buffer,
      output.offsetInBytes,
      documentModelInputSize * documentModelInputSize,
    );
    return _quadFromLogits(logits, frameWidth, frameHeight, inset);
  }

  /// Turns the page mask into a quadrilateral in frame coordinates, or null when
  /// no page region is found.
  DocumentQuad? _quadFromLogits(
    Float32List logits,
    int frameWidth,
    int frameHeight,
    int inset,
  ) {
    const size = documentModelInputSize;
    final mask = Uint8List(size * size);
    var any = false;
    for (var i = 0; i < size * size; i++) {
      if (1.0 / (1.0 + math.exp(-logits[i])) >= _threshold) {
        mask[i] = 1;
        any = true;
      }
    }
    if (!any) return null;
    return quadFromMask(
      mask,
      size: size,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      inset: inset,
    );
  }
}

/// Reduces a binary page mask (size x size) to a quadrilateral in frame
/// coordinates, or null when no page region is found.
DocumentQuad? quadFromMask(
  Uint8List mask, {
  required int size,
  required int frameWidth,
  required int frameHeight,
  int inset = 0,
}) {
  final pixels = _largestComponent(mask, size);
  if (pixels.length < 32) return null;
  final hull = _convexHull(pixels);
  if (hull.length < 4) return null;
  final quad = _reduceToQuad(hull);
  if (quad == null) return null;

  // Input space -> frame space: the frame was stretched over the input inside
  // the inset border, so undo both the stretch and the border.
  final span = size - 2 * inset;
  double toFrameX(double x) =>
      ((x - inset) * frameWidth / span).clamp(0.0, frameWidth - 1.0);
  double toFrameY(double y) =>
      ((y - inset) * frameHeight / span).clamp(0.0, frameHeight - 1.0);
  final pts = [for (final p in quad) math.Point(toFrameX(p.x), toFrameY(p.y))];
  return DocumentQuad(
    topLeft: pts[0],
    topRight: pts[1],
    bottomRight: pts[2],
    bottomLeft: pts[3],
  );
}

/// 4-connected component of `mask` with the most pixels, as points.
List<math.Point<double>> _largestComponent(Uint8List mask, int size) {
  final visited = Uint8List(size * size);
  var best = <int>[];
  final stack = <int>[];

  for (var start = 0; start < size * size; start++) {
    if (visited[start] != 0 || mask[start] == 0) continue;
    final component = <int>[];
    visited[start] = 1;
    stack.add(start);
    while (stack.isNotEmpty) {
      final index = stack.removeLast();
      component.add(index);
      final x = index % size;
      final y = index ~/ size;
      void push(int next) {
        if (visited[next] != 0 || mask[next] == 0) return;
        visited[next] = 1;
        stack.add(next);
      }

      if (x > 0) push(index - 1);
      if (x < size - 1) push(index + 1);
      if (y > 0) push(index - size);
      if (y < size - 1) push(index + size);
    }
    if (component.length > best.length) best = component;
  }

  return [
    for (final index in best)
      math.Point((index % size).toDouble(), (index ~/ size).toDouble()),
  ];
}

/// Andrew's monotone chain convex hull.
List<math.Point<double>> _convexHull(List<math.Point<double>> points) {
  final pts = List<math.Point<double>>.from(points)
    ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  if (pts.length < 4) return pts;

  double cross(
    math.Point<double> o,
    math.Point<double> a,
    math.Point<double> b,
  ) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

  final lower = <math.Point<double>>[];
  for (final p in pts) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <math.Point<double>>[];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Reduces a convex hull to the four most significant corners, ordered
/// clockwise from the top-left.
List<math.Point<double>>? _reduceToQuad(List<math.Point<double>> hull) {
  final pts = List<math.Point<double>>.from(hull);
  while (pts.length > 4) {
    var minIndex = 0;
    var minArea = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[(i - 1 + pts.length) % pts.length];
      final b = pts[i];
      final c = pts[(i + 1) % pts.length];
      final area =
          ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;
      if (area < minArea) {
        minArea = area;
        minIndex = i;
      }
    }
    pts.removeAt(minIndex);
  }
  if (pts.length != 4) return null;

  final n = pts.length;
  final cx = pts.map((p) => p.x).reduce((a, b) => a + b) / n;
  final cy = pts.map((p) => p.y).reduce((a, b) => a + b) / n;
  final sorted = List<math.Point<double>>.from(pts)
    ..sort(
      (a, b) => math
          .atan2(a.y - cy, a.x - cx)
          .compareTo(math.atan2(b.y - cy, b.x - cx)),
    );

  // Start at the corner nearest the top-left (smallest x + y).
  var start = 0;
  var best = double.infinity;
  for (var i = 0; i < n; i++) {
    final s = sorted[i].x + sorted[i].y;
    if (s < best) {
      best = s;
      start = i;
    }
  }
  return [for (var i = 0; i < n; i++) sorted[(start + i) % n]];
}

// --------------------------------------------------------------- preparing --

/// Samples a display-oriented RGBA buffer into the model input, in row-major
/// NHWC order.
Float32List prepareRgbaInput(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  final input = Float32List(
    documentModelInputSize * documentModelInputSize * 3,
  );
  final xStep = width / documentModelInputSize;
  final yStep = height / documentModelInputSize;
  var out = 0;
  for (var row = 0; row < documentModelInputSize; row++) {
    final y = (row + 0.5) * yStep - 0.5;
    for (var column = 0; column < documentModelInputSize; column++) {
      final x = (column + 0.5) * xStep - 0.5;
      final rgb = _sampleRgba(rgba, width, height, x, y);
      out = _writeNormalised(input, out, rgb.$1, rgb.$2, rgb.$3);
    }
  }
  return input;
}

/// Samples a camera YUV_420_888 frame (sensor-oriented planes, as the plugin
/// delivers them) into the model input, rotated for the display.
///
/// Each model pixel is the **average** of the sensor block it covers, not a
/// point sample: a live frame is dim and grainy compared with a captured photo,
/// and point sampling carries that grain straight into the model, which then
/// fails to see the page at all. The whole frame is then stretched to its own
/// 2nd..98th percentile, so a dim room reads like the well-lit photos the model
/// was trained on.
///
/// Sampling runs on the caller's isolate because the camera recycles the planes
/// as soon as the frame callback returns; only the prepared input crosses to the
/// detection worker.
Float32List prepareYuvInput({
  required Uint8List y,
  required Uint8List u,
  required Uint8List v,
  required int width,
  required int height,
  required int yRowStride,
  required int uvRowStride,
  required int uvPixelStride,
  required int rotationDegrees,
}) {
  const size = documentModelInputSize;
  const inner = size - 2 * _liveInset;
  final rotated = rotationDegrees == 90 || rotationDegrees == 270;
  final displayWidth = rotated ? height : width;
  final displayHeight = rotated ? width : height;

  // R, G and B for every model pixel, before the tone curve.
  final pixels = Float32List(size * size * 3);
  final border = Uint8List(size * size);
  final histogram = Int32List(256);
  var out = 0;
  for (var row = 0; row < size; row++) {
    final insideRow = row >= _liveInset && row < size - _liveInset;
    for (var column = 0; column < size; column++) {
      if (!insideRow || column < _liveInset || column >= size - _liveInset) {
        border[row * size + column] = 1;
        out += 3;
        continue;
      }
      final displayTop = (row - _liveInset) * displayHeight ~/ inner;
      final displayBottom = math.max(
        displayTop + 1,
        (row - _liveInset + 1) * displayHeight ~/ inner,
      );
      final displayLeft = (column - _liveInset) * displayWidth ~/ inner;
      final displayRight = math.max(
        displayLeft + 1,
        (column - _liveInset + 1) * displayWidth ~/ inner,
      );

      // The display block in sensor coordinates; quarter turns keep it an
      // axis-aligned block.
      final int left, right, top, bottom;
      switch (rotationDegrees) {
        case 90:
          left = displayTop;
          right = displayBottom;
          top = height - displayRight;
          bottom = height - displayLeft;
        case 180:
          left = width - displayRight;
          right = width - displayLeft;
          top = height - displayBottom;
          bottom = height - displayTop;
        case 270:
          left = width - displayBottom;
          right = width - displayTop;
          top = displayLeft;
          bottom = displayRight;
        default:
          left = displayLeft;
          right = displayRight;
          top = displayTop;
          bottom = displayBottom;
      }

      var luma = 0.0;
      var lumaCount = 0;
      for (var sy = top; sy < bottom && sy < height; sy++) {
        final rowStart = sy * yRowStride;
        for (var sx = left; sx < right && sx < width; sx++) {
          final index = rowStart + sx;
          if (index >= 0 && index < y.length) {
            luma += y[index];
            lumaCount++;
          }
        }
      }
      if (lumaCount == 0) {
        out += 3;
        continue;
      }
      luma /= lumaCount;

      var cb = 0.0;
      var cr = 0.0;
      var chromaCount = 0;
      for (var cy = top >> 1; cy <= (bottom - 1) >> 1; cy++) {
        final rowStart = cy * uvRowStride;
        for (var cx = left >> 1; cx <= (right - 1) >> 1; cx++) {
          final index = rowStart + cx * uvPixelStride;
          if (index >= 0 && index < u.length && index < v.length) {
            cb += u[index] - 128.0;
            cr += v[index] - 128.0;
            chromaCount++;
          }
        }
      }
      if (chromaCount > 0) {
        cb /= chromaCount;
        cr /= chromaCount;
      }

      // Full-range BT.601, matching what CameraX hands over.
      pixels[out++] = luma + 1.402 * cr;
      pixels[out++] = luma - 0.344136 * cb - 0.714136 * cr;
      pixels[out++] = luma + 1.772 * cb;
      histogram[luma.round().clamp(0, 255)]++;
    }
  }

  // The border takes the frame's own average tone: the model needs background
  // around the page, which a page that fills the view does not leave.
  var toneSum = 0.0;
  var toneCount = 0;
  for (var value = 0; value < histogram.length; value++) {
    toneSum += value * histogram[value];
    toneCount += histogram[value];
  }
  final borderTone = toneCount == 0 ? 0.0 : toneSum / toneCount;
  for (var pixel = 0; pixel < size * size; pixel++) {
    if (border[pixel] == 0) continue;
    pixels[pixel * 3] = borderTone;
    pixels[pixel * 3 + 1] = borderTone;
    pixels[pixel * 3 + 2] = borderTone;
  }

  // Auto-levels, then ImageNet normalisation, in one pass.
  var low = _percentile(histogram, 0.02).toDouble();
  final high = _percentile(histogram, 0.98).toDouble();
  var gain = 1.0;
  if (high - low >= 24) {
    gain = 255.0 / (high - low);
  } else {
    // A flat frame has nothing to stretch; leave its tone alone rather than
    // amplify grain into fake contrast.
    low = 0;
  }
  for (var i = 0; i < pixels.length; i += 3) {
    for (var channel = 0; channel < 3; channel++) {
      final value =
          ((pixels[i + channel] - low) * gain).clamp(0.0, 255.0) / 255.0;
      pixels[i + channel] =
          (value - _imagenetMean[channel]) / _imagenetStd[channel];
    }
  }
  return pixels;
}

/// Writes one ImageNet-normalised pixel, returning the next write offset.
int _writeNormalised(Float32List input, int out, double r, double g, double b) {
  input[out++] =
      (r.clamp(0.0, 255.0) / 255.0 - _imagenetMean[0]) / _imagenetStd[0];
  input[out++] =
      (g.clamp(0.0, 255.0) / 255.0 - _imagenetMean[1]) / _imagenetStd[1];
  input[out++] =
      (b.clamp(0.0, 255.0) / 255.0 - _imagenetMean[2]) / _imagenetStd[2];
  return out;
}

/// The value at [fraction] of a 0..255 histogram of sample counts.
int _percentile(Int32List histogram, double fraction) {
  var total = 0;
  for (final count in histogram) {
    total += count;
  }
  final target = (total * fraction).round();
  var seen = 0;
  for (var value = 0; value < histogram.length; value++) {
    seen += histogram[value];
    if (seen >= target) return value;
  }
  return histogram.length - 1;
}

/// Bilinear sample of an RGBA buffer, clamped at the edges.
(double, double, double) _sampleRgba(
  Uint8List rgba,
  int width,
  int height,
  double x,
  double y,
) {
  final x0 = x.floor().clamp(0, width - 1);
  final y0 = y.floor().clamp(0, height - 1);
  final x1 = (x0 + 1).clamp(0, width - 1);
  final y1 = (y0 + 1).clamp(0, height - 1);
  final fx = (x - x0).clamp(0.0, 1.0);
  final fy = (y - y0).clamp(0.0, 1.0);
  final i00 = (y0 * width + x0) * 4;
  final i10 = (y0 * width + x1) * 4;
  final i01 = (y1 * width + x0) * 4;
  final i11 = (y1 * width + x1) * 4;
  double channel(int offset) {
    final top = rgba[i00 + offset] * (1 - fx) + rgba[i10 + offset] * fx;
    final bottom = rgba[i01 + offset] * (1 - fx) + rgba[i11 + offset] * fx;
    return top * (1 - fy) + bottom * fy;
  }

  return (channel(0), channel(1), channel(2));
}
