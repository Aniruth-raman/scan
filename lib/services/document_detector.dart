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
  ///
  /// Dragging one corner across the opposite side makes the outline bow-tie, and
  /// dragging two corners together collapses an edge; either way the warp maps
  /// most of the source outside the page and the uncovered rest comes back
  /// white. This is the test that keeps that from being baked.
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

    // A page can be foreshortened, but no side of it collapses onto another.
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

/// Document corner detection with the DocAligner heatmap model
/// (DocsaidLab, Apache-2.0 — see `assets/models/LICENSE-docaligner.txt`).
///
/// The model is a 256x256 RGB heatmap regressor: it emits four 128x128 maps,
/// one per corner in clockwise order from the top-left. Each corner is the
/// value-weighted centroid of the largest connected region above
/// [_threshold], which is also the "is there a document" signal — a blank or
/// non-document frame never crosses the threshold, so nothing is returned and
/// the caller falls back to the full frame.
///
/// Everything is resolution independent: the input is rasterised to the model's
/// square input, and the returned quad is mapped back onto the caller's frame.
class DocumentDetector {
  DocumentDetector._(this._interpreter, this._inputSize, this._heatmapSize);

  /// A heatmap pixel at or above this is part of a corner.
  static const double _threshold = 0.3;

  /// Synthetic border (in input pixels) drawn around the frame before inference.
  ///
  /// DocAligner is a corner-heatmap model and needs the page to sit inside the
  /// frame with margin: a page that fills the frame scores ~0 and the detector
  /// falls back to the full frame. Padding the input restores the margin without
  /// cropping, and leaves a normally framed page unchanged (measured: test card
  /// corners still within 1 px).
  static const int _pad = 32;

  /// Border colour as a fraction of white (near-black, which the model reads as
  /// "outside the page").
  static const double _border = 13 / 255;

  final Interpreter _interpreter;
  final int _inputSize;
  final int _heatmapSize;

  /// Loads the model. Throws when the graph does not have the expected
  /// DocAligner fingerprint, so a bad asset fails loudly at startup rather than
  /// silently returning no detections.
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

    final heatTensor = interpreter.getOutputTensor(0);
    final heatShape = heatTensor.shape;
    if (heatShape.length != 4 || heatShape[3] != 4) {
      interpreter.close();
      throw StateError(
        'Unexpected document model output ${heatShape.join('x')}',
      );
    }

    debugPrint(
      'document model: input ${inputShape.join('x')} ${input.type.name}, '
      'heatmap ${heatShape.join('x')}',
    );
    return DocumentDetector._(interpreter, inputShape[1], heatShape[1]);
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
    final input = Float32List(_inputSize * _inputSize * 3)..fillRange(
      0,
      _inputSize * _inputSize * 3,
      _border,
    );
    final inner = _inputSize - 2 * _pad;
    final xStep = width / inner;
    final yStep = height / inner;
    for (var y = _pad; y < _inputSize - _pad; y++) {
      final sy = (y - _pad + 0.5) * yStep - 0.5;
      for (var x = _pad; x < _inputSize - _pad; x++) {
        final sx = (x - _pad + 0.5) * xStep - 0.5;
        final pixel = _sampleRgba(rgba, width, height, sx, sy);
        final offset = (y * _inputSize + x) * 3;
        input[offset] = pixel.$1 / 255.0;
        input[offset + 1] = pixel.$2 / 255.0;
        input[offset + 2] = pixel.$3 / 255.0;
      }
    }
    return _detect(input, width, height);
  }

  /// Detects a quad in a camera luminance (Y) plane.
  ///
  /// [width]/[height] describe the raw sensor frame; [rotationDegrees] (the
  /// camera's `sensorOrientation`) rotates it into display space and [mirrored]
  /// flips it horizontally, as front-camera previews do. The returned quad is
  /// in display coordinates, so width and height swap for 90/270 rotations.
  ///
  /// Luma is replicated across R/G/B: the model was trained on colour, but on a
  /// document the luminance carries the edges, and the measured corner shift
  /// against the colour path is under 1 px.
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

    final input = Float32List(_inputSize * _inputSize * 3)..fillRange(
      0,
      _inputSize * _inputSize * 3,
      _border,
    );
    final inner = _inputSize - 2 * _pad;
    final xStep = displayWidth / inner;
    final yStep = displayHeight / inner;
    for (var y = _pad; y < _inputSize - _pad; y++) {
      final displayY = (y - _pad + 0.5) * yStep - 0.5;
      for (var x = _pad; x < _inputSize - _pad; x++) {
        final displayX = (x - _pad + 0.5) * xStep - 0.5;
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
        final offset = (y * _inputSize + x) * 3;
        input[offset] = value;
        input[offset + 1] = value;
        input[offset + 2] = value;
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
    final heatmaps = Float32List.view(
      output.buffer,
      output.offsetInBytes,
      _heatmapSize * _heatmapSize * 4,
    );
    return detectQuadFromHeatmaps(
      heatmaps,
      heatmapSize: _heatmapSize,
      inputSize: _inputSize,
      pad: _pad,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
  }
}

/// Turns the four corner heatmaps into one quad in frame coordinates, or null
/// when any corner has no confident region (no document).
///
/// [heatmaps] is `heatmapSize * heatmapSize * 4` values in NHWC order. [pad] is
/// the synthetic border (in input pixels) that was added before inference, so
/// the heatmap coordinates are mapped back through it onto the frame.
DocumentQuad? detectQuadFromHeatmaps(
  Float32List heatmaps, {
  required int heatmapSize,
  required int inputSize,
  required int pad,
  required int frameWidth,
  required int frameHeight,
}) {
  // heatmap pixel -> input pixel -> frame pixel, skipping the border.
  final scale = inputSize / heatmapSize;
  final inner = inputSize - 2 * pad;
  final points = <math.Point<double>>[];
  for (var corner = 0; corner < 4; corner++) {
    final point = _cornerCentroid(heatmaps, corner, heatmapSize);
    if (point == null) return null;
    // Heatmap pixel -> input pixel -> frame pixel, undo the border and align
    // pixel centres at half a step.
    final inputX = point.$1 * scale + scale / 2 - pad;
    final inputY = point.$2 * scale + scale / 2 - pad;
    final x = inputX * frameWidth / inner - 0.5;
    final y = inputY * frameHeight / inner - 0.5;
    points.add(math.Point(x, y));
  }
  // DocAligner's channel order is clockwise from the top-left.
  return DocumentQuad(
    topLeft: points[0],
    topRight: points[1],
    bottomRight: points[2],
    bottomLeft: points[3],
  );
}

/// Weighted centroid of the largest region at or above [DocumentDetector._threshold]
/// in one corner map, or null when it has none.
(double, double)? _cornerCentroid(
  Float32List heatmaps,
  int corner,
  int size,
) {
  final visited = Uint8List(size * size);
  var bestArea = 0;
  var bestX = 0.0;
  var bestY = 0.0;
  var bestWeight = 0.0;

  for (var start = 0; start < size * size; start++) {
    if (visited[start] != 0) continue;
    if (heatmaps[start * 4 + corner] < DocumentDetector._threshold) continue;

    var area = 0;
    var sumX = 0.0;
    var sumY = 0.0;
    var sumWeight = 0.0;
    final stack = <int>[start];
    visited[start] = 1;

    while (stack.isNotEmpty) {
      final index = stack.removeLast();
      final x = index % size;
      final y = index ~/ size;
      final weight = heatmaps[index * 4 + corner];
      area++;
      sumX += x * weight;
      sumY += y * weight;
      sumWeight += weight;

      void push(int next) {
        if (visited[next] != 0) return;
        if (heatmaps[next * 4 + corner] < DocumentDetector._threshold) return;
        visited[next] = 1;
        stack.add(next);
      }

      if (x > 0) push(index - 1);
      if (x < size - 1) push(index + 1);
      if (y > 0) push(index - size);
      if (y < size - 1) push(index + size);
    }

    if (area > bestArea) {
      bestArea = area;
      bestX = sumX;
      bestY = sumY;
      bestWeight = sumWeight;
    }
  }

  if (bestArea == 0 || bestWeight == 0) return null;
  return (bestX / bestWeight, bestY / bestWeight);
}

// ------------------------------------------------------------------ mapping --

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
        // Display is the sensor frame rotated 90 degrees clockwise.
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
