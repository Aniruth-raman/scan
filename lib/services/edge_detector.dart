import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
}

/// Document edge detection over a camera luminance plane or a decoded image.
///
/// The detector is pure Dart and free of Flutter dependencies so it can run
/// inside an isolate. It finds the brightest large region (the document),
/// extracts its outline and returns a four-corner quad in display
/// coordinates, or null when no document-like region is visible.
class EdgeDetector {
  /// Maximum analysis width in pixels; larger inputs are downscaled, which
  /// keeps per-frame cost low on full camera streams.
  static const int maxAnalysisWidth = 240;

  /// A region smaller than this share of the frame is not a document.
  static const double minRegionFraction = 0.12;

  /// A region this close to covering the whole frame means there is no
  /// visible document border to crop to.
  static const double maxRegionFraction = 0.95;

  /// Detects a document quad in a camera Y plane.
  ///
  /// [width]/[height] describe the raw sensor frame; [rotationDegrees]
  /// (the camera's `sensorOrientation`) rotates it into display space and
  /// [mirrored] flips it horizontally as front-camera previews do.
  static DocumentQuad? detectInPlane(
    Uint8List y, {
    required int width,
    required int height,
    int bytesPerRow = 0,
    int rotationDegrees = 0,
    bool mirrored = false,
  }) {
    final stride = bytesPerRow == 0 ? width : bytesPerRow;
    final rotated = rotationDegrees == 90 || rotationDegrees == 270;
    final displayWidth = rotated ? height : width;
    final displayHeight = rotated ? width : height;

    final scale = math.min(
      1.0,
      maxAnalysisWidth / math.max(displayWidth, displayHeight),
    );
    final analysisWidth =
        math.max(16, (displayWidth * scale).round());
    final analysisHeight =
        math.max(16, (displayHeight * scale).round());

    // Build a display-oriented luminance buffer from the sensor plane.
    final gray = Uint8List(analysisWidth * analysisHeight);
    for (var vy = 0; vy < analysisHeight; vy++) {
      final displayY = (vy / (analysisHeight - 1)) * (displayHeight - 1);
      for (var vx = 0; vx < analysisWidth; vx++) {
        final displayX = (vx / (analysisWidth - 1)) * (displayWidth - 1);
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
        gray[vx + vy * analysisWidth] = y[sensor.x.round().clamp(0, width - 1) +
            sensor.y.round().clamp(0, height - 1) * stride];
      }
    }

    final quad = _detectQuad(
      gray,
      analysisWidth,
      analysisHeight,
    );
    if (quad == null) return null;
    final toDisplayX = displayWidth / analysisWidth;
    final toDisplayY = displayHeight / analysisHeight;
    return quad.scale(toDisplayX, toDisplayY);
  }

  /// Detects a document quad directly in a display-oriented decoded image.
  static DocumentQuad? detectInImage(img.Image image) {
    final width = image.width;
    final height = image.height;
    final scale = math.min(1.0, maxAnalysisWidth / math.max(width, height));
    final analysisWidth = math.max(16, (width * scale).round());
    final analysisHeight = math.max(16, (height * scale).round());
    final gray = Uint8List(analysisWidth * analysisHeight);
    for (var vy = 0; vy < analysisHeight; vy++) {
      final sy = ((vy / (analysisHeight - 1)) * (height - 1)).round();
      for (var vx = 0; vx < analysisWidth; vx++) {
        final sx = ((vx / (analysisWidth - 1)) * (width - 1)).round();
        final pixel = image.getPixel(sx, sy);
        gray[vx + vy * analysisWidth] = pixel.luminanceNormalized.isNaN
            ? 0
            : (pixel.luminanceNormalized * 255).round();
      }
    }
    final quad = _detectQuad(gray, analysisWidth, analysisHeight);
    if (quad == null) return null;
    return quad.scale(width / analysisWidth, height / analysisHeight);
  }

  /// Perspective-crops [image] to [quad], returning a rectangle whose size
  /// matches the quad's edge lengths.
  static img.Image cropToQuad(img.Image image, DocumentQuad quad) {
    double dist(math.Point<double> a, math.Point<double> b) =>
        math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

    final width = math
        .max(
          dist(quad.topLeft, quad.topRight),
          dist(quad.bottomLeft, quad.bottomRight),
        )
        .round()
        .clamp(8, 20000);
    final height = math
        .max(
          dist(quad.topLeft, quad.bottomLeft),
          dist(quad.topRight, quad.bottomRight),
        )
        .round()
        .clamp(8, 20000);

    img.Point p(math.Point<double> point) => img.Point(
          point.x.clamp(0, image.width - 1),
          point.y.clamp(0, image.height - 1),
        );

    return img.copyRectify(
      image,
      topLeft: p(quad.topLeft),
      topRight: p(quad.topRight),
      bottomLeft: p(quad.bottomLeft),
      bottomRight: p(quad.bottomRight),
      toImage: img.Image(width: width, height: height),
      interpolation: img.Interpolation.linear,
    );
  }

  /// Full-frame quad (no crop).
  static DocumentQuad fullFrame(int width, int height) => DocumentQuad(
        topLeft: math.Point(0, 0),
        topRight: math.Point(width - 1, 0),
        bottomRight: math.Point(width - 1, height - 1),
        bottomLeft: math.Point(0, height - 1),
      );

  static math.Point<double> _displayToSensor(
    double displayX,
    double displayY, {
    required int displayWidth,
    required int displayHeight,
    required int sensorWidth,
    required int sensorHeight,
    required int rotationDegrees,
    required bool mirrored,
  }) {
    var x = mirrored ? (displayWidth - 1) - displayX : displayX;
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

  // ---------------------------------------------------------------------
  // Core detection on a display-oriented grayscale buffer.
  // ---------------------------------------------------------------------

  static DocumentQuad? _detectQuad(Uint8List gray, int width, int height) {
    final total = width * height;
    if (total < 64) return null;

    final threshold = _otsu(gray);
    final mask = Uint8List(total);
    var bright = 0;
    for (var i = 0; i < total; i++) {
      // Strictly above the Otsu split: the split can land on the lower
      // mode itself, where '>=' would classify the whole frame as bright.
      if (gray[i] > threshold) {
        mask[i] = 1;
        bright++;
      }
    }
    final brightFraction = bright / total;
    if (brightFraction < 0.03 || brightFraction > 0.97) return null;

    final component = _largestComponent(mask, width, height);
    if (component == null) return null;
    final area = component.length / total;
    if (area < minRegionFraction || area > maxRegionFraction) return null;

    final hull = _convexHull(component, width);
    if (hull.length < 4) return null;
    final simplified =
        _rdp(hull, epsilon: 0.02 * math.sqrt(total.toDouble()));
    final quad = _bestQuad(simplified);
    if (quad == null) return null;

    // Reject outlines that are effectively the full frame.
    final frameArea = (width - 1) * (height - 1);
    if (_quadArea(quad) / frameArea > 0.95) return null;
    return quad;
  }

  static int _otsu(Uint8List gray) {
    final histogram = List<int>.filled(256, 0);
    for (final value in gray) {
      histogram[value]++;
    }
    final total = gray.length;
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    var sumBackground = 0;
    var weightBackground = 0;
    var best = 0;
    var bestVariance = -1.0;
    for (var i = 0; i < 256; i++) {
      weightBackground += histogram[i];
      if (weightBackground == 0) continue;
      final weightForeground = total - weightBackground;
      if (weightForeground == 0) break;
      sumBackground += i * histogram[i];
      final meanBackground = sumBackground / weightBackground;
      final meanForeground = (sum - sumBackground) / weightForeground;
      final delta = meanBackground - meanForeground;
      final variance =
          weightBackground * weightForeground * delta * delta;
      if (variance > bestVariance) {
        bestVariance = variance;
        best = i;
      }
    }
    return best;
  }

  static List<int>? _largestComponent(Uint8List mask, int width, int height) {
    final total = width * height;
    final labels = Int32List(total);
    final stack = <int>[];
    List<int>? best;
    var label = 0;
    for (var start = 0; start < total; start++) {
      if (mask[start] == 0 || labels[start] != 0) continue;
      label++;
      labels[start] = label;
      final component = <int>[start];
      stack.add(start);
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final x = index % width;
        final y = index ~/ width;
        void visit(int nx, int ny) {
          final ni = nx + ny * width;
          if (nx >= 0 &&
              nx < width &&
              ny >= 0 &&
              ny < height &&
              mask[ni] == 1 &&
              labels[ni] == 0) {
            labels[ni] = label;
            component.add(ni);
            stack.add(ni);
          }
        }

        if (x > 0) visit(x - 1, y);
        if (x < width - 1) visit(x + 1, y);
        if (y > 0) visit(x, y - 1);
        if (y < height - 1) visit(x, y + 1);
      }
      if (best == null || component.length > best.length) {
        best = component;
      }
    }
    return best;
  }

  /// Andrew's monotone chain convex hull over pixel coordinates.
  static List<math.Point<int>> _convexHull(
    List<int> indices,
    int width,
  ) {
    final points = <math.Point<int>>{
      for (final index in indices) math.Point(index % width, index ~/ width),
    }.toList()
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    if (points.length < 3) return points;

    double cross(math.Point<int> o, math.Point<int> a, math.Point<int> b) =>
        ((a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)).toDouble();

    final lower = <math.Point<int>>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <math.Point<int>>[];
    for (var i = points.length - 1; i >= 0; i--) {
      final point = points[i];
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  /// Ramer-Douglas-Peucker polygon simplification.
  static List<math.Point<int>> _rdp(
    List<math.Point<int>> points, {
    required double epsilon,
  }) {
    if (points.length < 3) return points;
    final keep = List<bool>.filled(points.length, false);
    keep[0] = keep[points.length - 1] = true;
    final stack = <(int, int)>[(0, points.length - 1)];
    while (stack.isNotEmpty) {
      final (start, end) = stack.removeLast();
      var maxDistance = 0.0;
      var index = -1;
      final a = points[start];
      final b = points[end];
      final abx = b.x - a.x;
      final aby = b.y - a.y;
      final ab2 = abx * abx + aby * aby;
      for (var i = start + 1; i < end; i++) {
        final p = points[i];
        final apx = p.x - a.x;
        final apy = p.y - a.y;
        final cross = apx * aby - apy * abx;
        final distance = ab2 == 0
            ? math.sqrt(apx * apx + apy * apy)
            : cross.abs() / math.sqrt(ab2);
        if (distance > maxDistance) {
          maxDistance = distance;
          index = i;
        }
      }
      if (index != -1 && maxDistance > epsilon) {
        keep[index] = true;
        stack.add((start, index));
        stack.add((index, end));
      }
    }
    return [for (var i = 0; i < points.length; i++) if (keep[i]) points[i]];
  }

  /// Picks the four hull vertices enclosing the largest convex area and
  /// orders them top-left, top-right, bottom-right, bottom-left.
  static DocumentQuad? _bestQuad(List<math.Point<int>> hull) {
    if (hull.length == 4) {
      return _orderQuad([
        for (final point in hull) math.Point<double>(point.x.toDouble(), point.y.toDouble()),
      ]);
    }
    if (hull.length < 4 || hull.length > 12) return null;

    DocumentQuad? best;
    double bestArea = 0;
    final n = hull.length;
    var a = 0;
    var b = a + 1;
    var c = b + 1;
    var d = c + 1;
    // Bounded exhaustive search over 4-subsets (C(12,4) = 495 worst case).
    while (a < n - 3) {
      b = a + 1;
      while (b < n - 2) {
        c = b + 1;
        while (c < n - 1) {
          d = c + 1;
          while (d < n) {
            final quad = _orderQuad([
              math.Point<double>(hull[a].x.toDouble(), hull[a].y.toDouble()),
              math.Point<double>(hull[b].x.toDouble(), hull[b].y.toDouble()),
              math.Point<double>(hull[c].x.toDouble(), hull[c].y.toDouble()),
              math.Point<double>(hull[d].x.toDouble(), hull[d].y.toDouble()),
            ]);
            final area = _quadArea(quad);
            if (area > bestArea) {
              bestArea = area;
              best = quad;
            }
            d++;
          }
          c++;
        }
        b++;
      }
      a++;
    }
    return best;
  }

  static DocumentQuad _orderQuad(List<math.Point<double>> points) {
    math.Point<double> tl = points.first;
    math.Point<double> br = points.first;
    math.Point<double> tr = points.first;
    math.Point<double> bl = points.first;
    for (final point in points) {
      if (point.x + point.y < tl.x + tl.y) tl = point;
      if (point.x + point.y > br.x + br.y) br = point;
      if (point.x - point.y > tr.x - tr.y) tr = point;
      if (point.x - point.y < bl.x - bl.y) bl = point;
    }
    return DocumentQuad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl);
  }

  static double _quadArea(DocumentQuad quad) {
    final points = quad.corners.toList();
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final current = points[i];
      final next = points[(i + 1) % 4];
      sum += current.x * next.y - next.x * current.y;
    }
    return sum.abs() / 2;
  }
}