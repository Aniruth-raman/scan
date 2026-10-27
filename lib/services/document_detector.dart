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

/// Document detection with a MobileNetV2 page-segmentation model
/// (trained with `tools/segmentation`, same family as Lens's detector).
///
/// The model is a 256x256 RGB segmenter: it emits a 256x256 page mask. The
/// largest connected region is reduced to a quadrilateral (convex hull, then
/// the four most significant corners), which is the outline the app draws.
///
/// A frame with no confident page produces no mask, so nothing is returned and
/// the caller falls back to the full frame.
class DocumentDetector {
  DocumentDetector._(this._interpreter, this._inputSize);

  /// A mask pixel at or above this (after sigmoid) is part of the page.
  static const double _threshold = 0.5;

  /// ImageNet normalisation, matching the training preprocessing.
  static const List<double> _mean = [0.485, 0.456, 0.406];
  static const List<double> _std = [0.229, 0.224, 0.225];

  final Interpreter _interpreter;
  final int _inputSize;

  /// Loads the model. Throws when the graph does not have the expected
  /// fingerprint, so a bad asset fails loudly at startup rather than silently
  /// returning no detections.
  static DocumentDetector load(Uint8List modelBytes) {
    final interpreter = Interpreter.fromBuffer(modelBytes);

    final input = interpreter.getInputTensor(0);
    final inputShape = input.shape;
    if (inputShape.length != 4 ||
        inputShape[1] != inputShape[2] ||
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
    return DocumentDetector._(interpreter, inputShape[1]);
  }

  // --------------------------------------------------------------- surfaces --

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
    final input = Float32List(_inputSize * _inputSize * 3);
    final xStep = width / _inputSize;
    final yStep = height / _inputSize;
    var out = 0;
    for (var y = 0; y < _inputSize; y++) {
      final sy = (y + 0.5) * yStep - 0.5;
      for (var x = 0; x < _inputSize; x++) {
        final sx = (x + 0.5) * xStep - 0.5;
        final pixel = _sampleRgba(rgba, width, height, sx, sy);
        input[out++] = (pixel.$1 / 255.0 - _mean[0]) / _std[0];
        input[out++] = (pixel.$2 / 255.0 - _mean[1]) / _std[1];
        input[out++] = (pixel.$3 / 255.0 - _mean[2]) / _std[2];
      }
    }
    return _detect(input, width, height);
  }

  /// Detects a quad in a camera luminance (Y) plane.
  ///
  /// Luma is replicated across R/G/B (the live feed has no colour buffer); the
  /// crop stage re-detects on the colour capture, so its corners stay exact.
  DocumentQuad? detectFromLuma(
    Uint8List luma, {
    required int width,
    required int height,
    int bytesPerRow = 0,
    int rotationDegrees = 0,
    bool mirrored = false,
  }) {
    if (width < 8 || height < 8) return null;
    final stride = bytesPerRow == 0 ? width : bytesPerRow;
    final rotated = rotationDegrees == 90 || rotationDegrees == 270;
    final displayWidth = rotated ? height : width;
    final displayHeight = rotated ? width : height;

    final input = Float32List(_inputSize * _inputSize * 3);
    final xStep = displayWidth / _inputSize;
    final yStep = displayHeight / _inputSize;
    var out = 0;
    for (var y = 0; y < _inputSize; y++) {
      final displayY = (y + 0.5) * yStep - 0.5;
      for (var x = 0; x < _inputSize; x++) {
        final displayX = (x + 0.5) * xStep - 0.5;
        final sensor = _displayToSensor(
          displayX,
          displayY,
          displayWidth: displayWidth,
          displayHeight: displayHeight,
          sensorWidth: width,
          sensorHeight: height,
          rotationDegrees: rotationDegrees,
          mirrored: mirrored,
        );
        final sx = sensor.x.round().clamp(0, width - 1);
        final sy = sensor.y.round().clamp(0, height - 1);
        final value = luma[sx + sy * stride] / 255.0;
        input[out++] = (value - _mean[0]) / _std[0];
        input[out++] = (value - _mean[1]) / _std[1];
        input[out++] = (value - _mean[2]) / _std[2];
      }
    }
    return _detect(input, displayWidth, displayHeight);
  }

  // ------------------------------------------------------------- inference ---

  DocumentQuad? _detect(Float32List input, int frameWidth, int frameHeight) {
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
      _inputSize * _inputSize,
    );
    return _quadFromLogits(logits, frameWidth, frameHeight);
  }

  /// Turns the page mask into a quadrilateral in frame coordinates, or null when
  /// no page region is found.
  DocumentQuad? _quadFromLogits(
    Float32List logits,
    int frameWidth,
    int frameHeight,
  ) {
    final size = _inputSize;
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
}) {
  final pixels = _largestComponent(mask, size);
  if (pixels.length < 32) return null;
  final hull = _convexHull(pixels);
  if (hull.length < 4) return null;
  final quad = _reduceToQuad(hull);
  if (quad == null) return null;

  // Input space -> frame space (the frame was stretched to the square input).
  final sx = frameWidth / size;
  final sy = frameHeight / size;
  final pts = [for (final p in quad) math.Point(p.x * sx, p.y * sy)];
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

    double cross(math.Point<double> o, math.Point<double> a, math.Point<double> b) =>
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

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

  // --------------------------------------------------------------- mapping ---

  math.Point<double> _displayToSensor(
    double displayX,
    double displayY, {
    required int displayWidth,
    required int displayHeight,
    required int sensorWidth,
    required int sensorHeight,
    required int rotationDegrees,
    required bool mirrored,
  }) {
    final x = mirrored ? (displayWidth - 1) - displayX : displayX;
    final y = displayY;
    switch (rotationDegrees) {
      case 90:
        return math.Point(y, (sensorHeight - 1) - x);
      case 180:
        return math.Point((sensorWidth - 1) - x, (sensorHeight - 1) - y);
      case 270:
        return math.Point((sensorWidth - 1) - y, x);
      default:
        return math.Point(x, y);
    }
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
