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

/// Document edge detection with the M-LSD model
/// ("Towards Light-weight and Real-time Line Segment Detection", NAVER Corp,
/// Apache-2.0 — see `assets/models/LICENSE-mlsd.txt`).
///
/// The model is a TFLite Mobile Line Segment Detector: it consumes an
/// RGBA image and emits segment centres, their scores, and a displacement map.
/// Corners then come from `pred_squares`, the reference post-processing shipped
/// with the model, ported here so the geometry matches the published behaviour
/// instead of hand-tuned heuristics.
///
/// Everything is resolution independent: the input is rasterised to the model's
/// square input, and the returned quad is mapped back onto the caller's frame.
class DocumentDetector {
  DocumentDetector._(
    this._interpreter,
    this._modelSize,
    this._mapSize,
    this._pointCount,
  );

  /// Reference coordinate space of the published post-processing. M-LSD's
  /// constants (segment length threshold, Hough quantisation, score weights)
  /// are all tuned for a 512 px input with a 256 px output map, so the geometry
  /// runs in that space and is scaled to the real frame at the end.
  static const double _refSize = 512.0;

  /// `dist_thr = 20` in the reference's 256 px map space, doubled into [_refSize].
  static const double _minSegmentDistance = 40.0;

  /// `params['score']` in the reference.
  static const double _scoreThreshold = 0.06;

  /// The reference only accepts intersections with 60-120 degrees between arms.
  static const double _minCornerDegrees = 60.0;
  static const double _maxCornerDegrees = 120.0;

  /// `params` weights. The reference also computes overlap and length terms,
  /// but both carry a weight of zero, so they cannot affect the choice.
  static const double _wDegree = 1.95;
  static const double _wArea = 1.86;
  static const double _wCenter = 0.14;

  /// Centre of [_refSize] space and its half-diagonal, for the centre penalty.
  static const double _refCenter = _refSize / 2;
  static const double _refCenterNorm = _refSize / 1.4142135623730951;

  /// A quad smaller than this share of the frame is not a document.
  static const double _minAreaFraction = 0.04;

  final Interpreter _interpreter;
  final int _modelSize;
  final int _mapSize;
  final int _pointCount;

  int get inputSize => _modelSize;

  /// Loads the model. Throws when the graph does not have the expected M-LSD
  /// fingerprint, so a bad asset fails loudly at startup rather than silently
  /// returning no detections.
  static DocumentDetector load(Uint8List modelBytes) {
    final interpreter = Interpreter.fromBuffer(modelBytes);

    final input = interpreter.getInputTensor(0);
    final inputShape = input.shape;
    if (inputShape.length != 4 ||
        inputShape[1] != inputShape[2] ||
        inputShape[3] != 4) {
      interpreter.close();
      throw StateError('Unexpected document model input ${inputShape.join('x')}');
    }
    if (input.type != TensorType.float32) {
      interpreter.close();
      throw StateError('Document model expects ${input.type} input');
    }

    final pointTensor = interpreter.getOutputTensor(0);
    final scoreTensor = interpreter.getOutputTensor(1);
    final mapTensor = interpreter.getOutputTensor(2);
    final pointShape = pointTensor.shape;
    final mapShape = mapTensor.shape;
    final scoreShape = scoreTensor.shape;
    if (pointShape.length != 3 ||
        mapShape.length != 4 ||
        scoreShape.length != 2 ||
        scoreShape[1] != pointShape[1]) {
      interpreter.close();
      throw StateError(
        'Unexpected document model outputs '
        '${pointShape.join('x')}, ${mapShape.join('x')}',
      );
    }

    debugPrint(
      'document model: input ${inputShape.join('x')} ${input.type.name}, '
      'map ${mapShape.join('x')}, ${pointShape[1]} points',
    );
    return DocumentDetector._(
      interpreter,
      inputShape[1],
      mapShape[1],
      pointShape[1],
    );
  }

  void dispose() => _interpreter.close();

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
    final input = Float32List(_modelSize * _modelSize * 4);
    final xStep = width / _modelSize;
    final yStep = height / _modelSize;
    var out = 0;
    for (var y = 0; y < _modelSize; y++) {
      final sy = (y + 0.5) * yStep - 0.5;
      for (var x = 0; x < _modelSize; x++) {
        final sx = (x + 0.5) * xStep - 0.5;
        final pixel = _sampleRgba(rgba, width, height, sx, sy);
        input[out++] = pixel.$1;
        input[out++] = pixel.$2;
        input[out++] = pixel.$3;
        // The stem layer multiplies alpha by zero, so the value is irrelevant;
        // 1.0 matches the reference feed.
        input[out++] = 1.0;
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

    final input = Float32List(_modelSize * _modelSize * 4);
    final xStep = displayWidth / _modelSize;
    final yStep = displayHeight / _modelSize;
    var out = 0;
    for (var y = 0; y < _modelSize; y++) {
      final displayY = (y + 0.5) * yStep - 0.5;
      for (var x = 0; x < _modelSize; x++) {
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
        final value = luma[sx + sy * stride].toDouble();
        input[out++] = value;
        input[out++] = value;
        input[out++] = value;
        input[out++] = 1.0;
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

    final points = _interpreter.getOutputTensor(0).data;
    final scores = _interpreter.getOutputTensor(1).data;
    final map = _interpreter.getOutputTensor(2).data;

    final pointValues = Int32List.view(
      points.buffer,
      points.offsetInBytes,
      _pointCount * 2,
    );
    final scoreValues = Float32List.view(
      scores.buffer,
      scores.offsetInBytes,
      _pointCount,
    );
    final mapValues = Float32List.view(
      map.buffer,
      map.offsetInBytes,
      _mapSize * _mapSize * 4,
    );

    return detectQuadFromSegments(
      _decodeSegments(scoreValues, pointValues, mapValues),
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
  }

  /// Decodes the model's point list into segments, in reference space.
  List<Segment> _decodeSegments(
    Float32List scores,
    Int32List points,
    Float32List map,
  ) {
    // Map pixels -> reference space. A 256 px map (the reference's 512 input)
    // lands on 512 exactly, so both map sizes share one code path.
    final scale = _refSize / _mapSize;
    final segments = <Segment>[];
    for (var i = 0; i < _pointCount; i++) {
      if (scores[i] <= _scoreThreshold) continue;
      final y = points[i * 2];
      final x = points[i * 2 + 1];
      if (x < 0 || y < 0 || x >= _mapSize || y >= _mapSize) continue;
      final base = (y * _mapSize + x) * 4;
      final dxStart = map[base];
      final dyStart = map[base + 1];
      final dxEnd = map[base + 2];
      final dyEnd = map[base + 3];
      final distance = math.sqrt(
        (dxEnd - dxStart) * (dxEnd - dxStart) +
            (dyEnd - dyStart) * (dyEnd - dyStart),
      );
      if (distance * scale <= _minSegmentDistance) continue;
      segments.add(
        Segment(
          (x + dxStart) * scale,
          (y + dyStart) * scale,
          (x + dxEnd) * scale,
          (y + dyEnd) * scale,
        ),
      );
    }
    return segments;
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
}

/// One decoded line segment in reference space.
class Segment {
  const Segment(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;
}

/// A merged, infinite line (stored as its endpoints) in reference space.
class _Line {
  _Line(this.x1, this.y1, this.x2, this.y2);

  final double x1, y1, x2, y2;

  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
}

/// An intersection of two lines, tagged with the corner class it belongs to
/// (0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left).
class _Corner {
  const _Corner(this.x, this.y, this.lineA, this.lineB);

  final double x;
  final double y;
  final int lineA;
  final int lineB;

  bool sharesLineWith(_Corner other) =>
      lineA == other.lineA ||
      lineA == other.lineB ||
      lineB == other.lineA ||
      lineB == other.lineB;
}

/// Fits a document quad to M-LSD segments.
///
/// This is a port of `pred_squares` from the model's reference implementation.
/// The reference also scores overlap and side-length balance, but both weights
/// are zero, so only corner balance, area and distance from the centre decide
/// the winner here. Everything runs in the 512 px reference space and is scaled
/// onto [frameWidth] x [frameHeight] at the end.
DocumentQuad? detectQuadFromSegments(
  List<Segment> segments, {
  required int frameWidth,
  required int frameHeight,
}) {
  if (segments.length < 4) return null;
  final lines = _mergeCollinear(segments);
  if (lines.length < 4) return null;
  final corners = _classifyCorners(lines);
  if (corners.any((bucket) => bucket.isEmpty)) return null;

  List<_Corner>? best;
  var bestScore = 0.0;
  for (final topLeft in corners[0]) {
    for (final topRight in corners[1]) {
      if (!topLeft.sharesLineWith(topRight)) continue;
      for (final bottomRight in corners[2]) {
        if (!topRight.sharesLineWith(bottomRight)) continue;
        for (final bottomLeft in corners[3]) {
          if (!bottomRight.sharesLineWith(bottomLeft)) continue;
          if (!bottomLeft.sharesLineWith(topLeft)) continue;
          final quad = [topLeft, topRight, bottomRight, bottomLeft];
          final area = _areaFraction(quad);
          if (area < DocumentDetector._minAreaFraction) continue;
          final score = _score(quad, area);
          if (best == null || score > bestScore) {
            best = quad;
            bestScore = score;
          }
        }
      }
    }
  }

  final quad = best;
  if (quad == null) return null;

  final scaleX = frameWidth / 512.0;
  final scaleY = frameHeight / 512.0;
  return DocumentQuad(
    topLeft: math.Point(quad[0].x * scaleX, quad[0].y * scaleY),
    topRight: math.Point(quad[1].x * scaleX, quad[1].y * scaleY),
    bottomRight: math.Point(quad[2].x * scaleX, quad[2].y * scaleY),
    bottomLeft: math.Point(quad[3].x * scaleX, quad[3].y * scaleY),
  );
}

// ------------------------------------------------------------------ merging --

/// Collapses segments onto their dominant Hough lines (reference step 1).
List<_Line> _mergeCollinear(List<Segment> segments) {
  const dQuant = 1;
  const tQuant = 2;
  final dCells = (512 ~/ dQuant) + 1;
  final tCells = (360 ~/ tQuant) + 1;
  final counts = Int32List(dCells * tCells);
  final members = List<List<int>?>.filled(dCells * tCells, null);
  final angles = Float64List(segments.length);
  final dCell = Int32List(segments.length);
  final tCell = Int32List(segments.length);

  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final dx = s.x1 - s.x2;
    final dy = s.y1 - s.y2;
    final a = dy;
    final b = -dx;
    final c = a * s.x1 + b * s.y1;
    final distance = c.abs() / math.sqrt(a * a + b * b + 1e-10);
    var angle = math.atan2(dx, dy) * 180 / math.pi;
    if (angle < 0) angle += 180;
    angles[i] = angle;
    final di = (distance ~/ dQuant).clamp(0, dCells - 1);
    final ti = (angle ~/ tQuant).clamp(0, tCells - 1);
    dCell[i] = di;
    tCell[i] = ti;
    final cell = di * tCells + ti;
    counts[cell]++;
    (members[cell] ??= <int>[]).add(i);
  }

  // Keep cells that are a local maximum over 5x5 (the reference's max-pool).
  final peaks = <int>[];
  for (var di = 0; di < dCells; di++) {
    for (var ti = 0; ti < tCells; ti++) {
      final cell = di * tCells + ti;
      final count = counts[cell];
      if (count == 0) continue;
      var isPeak = true;
      for (var dy = -2; dy <= 2 && isPeak; dy++) {
        final nd = di + dy;
        if (nd < 0 || nd >= dCells) continue;
        for (var dx = -2; dx <= 2; dx++) {
          final nt = ti + dx;
          if (nt < 0 || nt >= tCells) continue;
          if (counts[nd * tCells + nt] > count) {
            isPeak = false;
            break;
          }
        }
      }
      if (isPeak) peaks.add(cell);
    }
  }
  peaks.sort((a, b) => counts[b].compareTo(counts[a]));

  final lines = <_Line>[];
  final limit = math.min(peaks.length, segments.length);
  for (var p = 0; p < limit; p++) {
    final cell = peaks[p];
    final di = cell ~/ tCells;
    final ti = cell % tCells;
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    var angle = 0.0;
    var any = false;
    for (var dy = -2; dy <= 2; dy++) {
      final nd = di + dy;
      if (nd < 0 || nd >= dCells) continue;
      for (var dx = -2; dx <= 2; dx++) {
        final nt = ti + dx;
        if (nt < 0 || nt >= tCells) continue;
        final list = members[nd * tCells + nt];
        if (list == null) continue;
        for (final index in list) {
          final s = segments[index];
          minX = math.min(minX, math.min(s.x1, s.x2));
          maxX = math.max(maxX, math.max(s.x1, s.x2));
          minY = math.min(minY, math.min(s.y1, s.y2));
          maxY = math.max(maxY, math.max(s.y1, s.y2));
          angle = angles[index];
          any = true;
        }
      }
    }
    if (!any || maxX - minX < 1 || maxY - minY < 1) continue;
    if (angle >= 90) {
      lines.add(_Line(minX, maxY, maxX, minY));
    } else {
      lines.add(_Line(minX, minY, maxX, maxY));
    }
  }
  return lines;
}

// ------------------------------------------------------------- intersections --

/// Reference step 3: intersect every pair of lines and bucket by corner class.
List<List<_Corner>> _classifyCorners(List<_Line> lines) {
  final corners = List.generate(4, (_) => <_Corner>[]);
  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      final point = _intersect(lines[i], lines[j]);
      if (point == null) continue;

      final degI = _degrees(point.$1, point.$2, lines[i].centerX, lines[i].centerY);
      final degJ = _degrees(point.$1, point.$2, lines[j].centerX, lines[j].centerY);
      final sorted = degI <= degJ ? [degI, degJ] : [degJ, degI];
      final low = sorted[0];
      final high = sorted[1];

      var difference = (degI - degJ).abs();
      if (difference > 180) difference = 360 - difference;
      if (difference <= DocumentDetector._minCornerDegrees ||
          difference >= DocumentDetector._maxCornerDegrees) {
        continue;
      }
      // The corner has to sit on (or just past) both segments, otherwise every
      // extrapolated pair of lines would produce a candidate.
      if (!_crossesSegment(lines[i], point.$1, point.$2)) continue;
      if (!_crossesSegment(lines[j], point.$1, point.$2)) continue;

      final int cornerClass;
      if ((low >= 0 && low <= 45 && high >= 45 && high <= 120) ||
          (high >= 315 && low >= 45 && low <= 120)) {
        cornerClass = 0;
      } else if (low >= 45 && low <= 125 && high >= 125 && high <= 225) {
        cornerClass = 1;
      } else if (low >= 125 && low <= 225 && high >= 225 && high <= 315) {
        cornerClass = 2;
      } else if ((low >= 0 && low <= 45 && high >= 225 && high <= 315) ||
          (high >= 315 && low >= 225 && low <= 315)) {
        cornerClass = 3;
      } else {
        continue;
      }
      corners[cornerClass].add(_Corner(point.$1, point.$2, i, j));
    }
  }
  return corners;
}

/// True when the intersection is on the segment, or just beyond one end.
///
/// Mirrors `check_distance` in the reference: a corner is plausible when it
/// falls inside the drawn segment, or outside it by at most 28% of its length
/// (a corner cut off by the frame edge).
bool _crossesSegment(_Line line, double x, double y) {
  final dx = line.x2 - line.x1;
  final dy = line.y2 - line.y1;
  final length = math.sqrt(dx * dx + dy * dy);
  if (length < 1e-6) return false;
  final d1 = math.sqrt((x - line.x1) * (x - line.x1) + (y - line.y1) * (y - line.y1));
  final d2 = math.sqrt((x - line.x2) * (x - line.x2) + (y - line.y2) * (y - line.y2));
  final near = d1 < d2 ? d1 : d2;
  final far = d1 < d2 ? d2 : d1;
  if (far <= length) return near <= length * _insideRatio;
  return near <= length * _outsideRatio;
}

/// `params['inside_ratio']` / `params['outside_ratio']`.
const double _insideRatio = 0.45;
const double _outsideRatio = 0.28;

/// Intersection of two lines, or null when they are near parallel.
(double, double)? _intersect(_Line a, _Line b) {
  final ax = a.x1 - a.x2;
  final ay = a.y1 - a.y2;
  final bx = b.x1 - b.x2;
  final by = b.y1 - b.y2;
  final ac = ay * a.x1 - ax * a.y1;
  final bc = by * b.x1 - bx * b.y1;
  final det = ay * (-bx) - by * (-ax);
  if (det.abs() < 1e-6) return null;
  final x = (ac * (-bx) - bc * (-ax)) / det;
  final y = (ay * bc - by * ac) / det;
  return (x, y);
}

/// Direction from ([ox],[oy]) to ([tx],[ty]) in degrees, normalised to 0-360.
double _degrees(double ox, double oy, double tx, double ty) {
  var value = math.atan2(ty - oy, tx - ox) * 180 / math.pi;
  if (value < 0) value += 360;
  return value;
}

// ------------------------------------------------------------------ scoring --

/// Shoelace area of the quad as a share of the reference frame.
double _areaFraction(List<_Corner> quad) {
  var sum = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    sum += a.x * b.y - b.x * a.y;
  }
  return (sum.abs() / 2) / (512.0 * 512.0);
}

/// The reference's weighted score, minus the two zero-weight terms.
double _score(List<_Corner> quad, double areaFraction) {
  final degrees = Float64List(4);
  for (var i = 0; i < 4; i++) {
    final previous = quad[(i + 3) % 4];
    final next = quad[(i + 1) % 4];
    final current = quad[i];
    final v1x = previous.x - current.x;
    final v1y = previous.y - current.y;
    final v2x = next.x - current.x;
    final v2y = next.y - current.y;
    final norm = math.sqrt(
          (v1x * v1x + v1y * v1y) * (v2x * v2x + v2y * v2y),
        ) +
        1e-10;
    final cosine = ((v1x * v2x + v1y * v2y) / norm).clamp(-1.0, 1.0);
    degrees[i] = math.acos(cosine) * 180 / math.pi;
  }

  // Opposite corners should open by similar amounts.
  final ratio02 = _ratio(degrees[0], degrees[2]);
  final ratio13 = _ratio(degrees[1], degrees[3]);
  final degreeScore = (ratio02 + ratio13) / 2;

  final centerX = (quad[0].x + quad[1].x + quad[2].x + quad[3].x) / 4;
  final centerY = (quad[0].y + quad[1].y + quad[2].y + quad[3].y) / 4;
  final centerDistance = math.sqrt(
    (centerX - DocumentDetector._refCenter) *
            (centerX - DocumentDetector._refCenter) +
        (centerY - DocumentDetector._refCenter) *
            (centerY - DocumentDetector._refCenter),
  );

  return DocumentDetector._wDegree * degreeScore +
      DocumentDetector._wArea * areaFraction -
      DocumentDetector._wCenter *
          (centerDistance / DocumentDetector._refCenterNorm);
}

double _ratio(double a, double b) {
  if (a <= 0 || b <= 0) return 0;
  final ratio = a / b;
  return ratio > 1 ? 1 / ratio : ratio;
}
