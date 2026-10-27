import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan/services/document_detector.dart';

/// Builds a [size] x [size] x 4 heatmap with a Gaussian blob for each corner,
/// at the given heatmap-space centres, in DocAligner's channel order
/// (top-left, top-right, bottom-right, bottom-left).
Float32List _heatmapsWithCorners(
  int size,
  List<(double, double)> centres, {
  double peak = 0.9,
  double sigma = 1.5,
}) {
  final data = Float32List(size * size * 4);
  for (var c = 0; c < 4; c++) {
    final (cx, cy) = centres[c];
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x - cx;
        final dy = y - cy;
        data[(y * size + x) * 4 + c] =
            peak * math.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
      }
    }
  }
  return data;
}

void main() {
  group('detectQuadFromHeatmaps', () {
    test('recovers the four corner blobs and scales them to the frame', () {
      const size = 32;
      final corners = <(double, double)>[
        (6, 6),
        (26, 6),
        (26, 26),
        (6, 26),
      ];
      final quad = detectQuadFromHeatmaps(
        _heatmapsWithCorners(size, corners),
        heatmapSize: size,
        inputSize: size,
        pad: 0,
        frameWidth: 320,
        frameHeight: 320,
      );

      expect(quad, isNotNull);
      // Heatmap pixel p maps to (p + 0.5) * 320/32 - 0.5 = (p + 0.5)*10 - 0.5.
      double frame(double p) => (p + 0.5) * 320 / size - 0.5;

      expect(quad!.topLeft.x, closeTo(frame(6), 2));
      expect(quad.topLeft.y, closeTo(frame(6), 2));
      expect(quad.topRight.x, closeTo(frame(26), 2));
      expect(quad.topRight.y, closeTo(frame(6), 2));
      expect(quad.bottomRight.x, closeTo(frame(26), 2));
      expect(quad.bottomRight.y, closeTo(frame(26), 2));
      expect(quad.bottomLeft.x, closeTo(frame(6), 2));
      expect(quad.bottomLeft.y, closeTo(frame(26), 2));
      // The recovered corners still describe a usable page.
      expect(quad.isUsable, isTrue);
    });

    test('an empty frame has no corner above the threshold', () {
      final quad = detectQuadFromHeatmaps(
        Float32List(32 * 32 * 4), // all zero
        heatmapSize: 32,
        inputSize: 32,
        pad: 0,
        frameWidth: 320,
        frameHeight: 320,
      );
      expect(quad, isNull);
    });

    test('a missing corner map rejects the whole quad', () {
      final heatmaps = _heatmapsWithCorners(32, const [
        (6, 6),
        (26, 6),
        (26, 26),
        (6, 26),
      ]);
      // Wipe the bottom-left channel only.
      for (var i = 0; i < 32 * 32; i++) {
        heatmaps[i * 4 + 3] = 0;
      }
      final quad = detectQuadFromHeatmaps(
        heatmaps,
        heatmapSize: 32,
        inputSize: 32,
        pad: 0,
        frameWidth: 320,
        frameHeight: 320,
      );
      expect(quad, isNull, reason: 'all four corners are required');
    });

    test('the largest blob wins over a stray speck', () {
      const size = 32;
      final heatmaps = _heatmapsWithCorners(size, const [
        (6, 6),
        (26, 6),
        (26, 26),
        (6, 26),
      ]);
      // Add a strong but tiny speck in the top-left channel, away from the blob.
      heatmaps[(20 * size + 20) * 4 + 0] = 0.95;
      final quad = detectQuadFromHeatmaps(
        heatmaps,
        heatmapSize: size,
        inputSize: size,
        pad: 0,
        frameWidth: 320,
        frameHeight: 320,
      );
      expect(quad, isNotNull);
      // Still the real top-left blob, not the one-pixel speck.
      expect(quad!.topLeft.x, closeTo((6 + 0.5) * 10 - 0.5, 2));
    });
  });

  group('DocumentQuad', () {
    test('fullFrame covers the frame edges', () {
      final quad = DocumentQuad.fullFrame(100, 50);
      expect(quad.topLeft, const math.Point(0.0, 0.0));
      expect(quad.topRight, const math.Point(99.0, 0.0));
      expect(quad.bottomRight, const math.Point(99.0, 49.0));
      expect(quad.bottomLeft, const math.Point(0.0, 49.0));
    });

    test('scale maps preview coordinates to capture coordinates', () {
      final quad = DocumentQuad.fullFrame(10, 10).scale(4, 2);
      expect(quad.bottomRight, const math.Point(36.0, 18.0));
    });

    test('a perspective page is usable', () {
      const quad = DocumentQuad(
        topLeft: math.Point(180, 120),
        topRight: math.Point(620, 90),
        bottomRight: math.Point(700, 620),
        bottomLeft: math.Point(90, 680),
      );
      expect(quad.isUsable, isTrue);
    });

    test('corners dragged past each other are not usable', () {
      const bowTie = DocumentQuad(
        topLeft: math.Point(100, 100),
        topRight: math.Point(400, 400),
        bottomRight: math.Point(400, 100),
        bottomLeft: math.Point(100, 400),
      );
      expect(bowTie.isUsable, isFalse);
    });

    test('two corners dragged together are not usable', () {
      const sliver = DocumentQuad(
        topLeft: math.Point(100, 100),
        topRight: math.Point(400, 100),
        bottomRight: math.Point(400, 105),
        bottomLeft: math.Point(100, 105),
      );
      expect(sliver.isUsable, isFalse);
    });

    test('collinear corners are not usable', () {
      const flat = DocumentQuad(
        topLeft: math.Point(0, 0),
        topRight: math.Point(100, 0),
        bottomRight: math.Point(200, 0),
        bottomLeft: math.Point(100, 0),
      );
      expect(flat.isUsable, isFalse);
    });

    test('distanceTo measures the worst corner', () {
      final a = DocumentQuad.fullFrame(100, 100);
      final b = a.scale(1, 1);
      expect(a.distanceTo(b), 0);
      final moved = DocumentQuad(
        topLeft: const math.Point(3, 4),
        topRight: a.topRight,
        bottomRight: a.bottomRight,
        bottomLeft: a.bottomLeft,
      );
      expect(a.distanceTo(moved), closeTo(5, 1e-9));
    });
  });
}
