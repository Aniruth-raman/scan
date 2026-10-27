import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scan/services/document_detector.dart';

Uint8List _rectangle(int size, int x0, int y0, int x1, int y1) {
  final mask = Uint8List(size * size);
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      mask[y * size + x] = 1;
    }
  }
  return mask;
}

void main() {
  group('quadFromMask', () {
    test('a filled page rectangle becomes its four corners', () {
      const size = 64;
      final quad = quadFromMask(
        _rectangle(size, 13, 13, 51, 51),
        size: size,
        frameWidth: 640,
        frameHeight: 640,
      );

      expect(quad, isNotNull);
      const scale = 640 / size; // 10
      double px(double v) => v * scale;
      // Pixels 13..50 inclusive -> frame 130..500.
      expect(quad!.topLeft.x, closeTo(px(13), 2));
      expect(quad.topLeft.y, closeTo(px(13), 2));
      expect(quad.topRight.x, closeTo(px(50), 2));
      expect(quad.topRight.y, closeTo(px(13), 2));
      expect(quad.bottomRight.x, closeTo(px(50), 2));
      expect(quad.bottomRight.y, closeTo(px(50), 2));
      expect(quad.bottomLeft.x, closeTo(px(13), 2));
      expect(quad.bottomLeft.y, closeTo(px(50), 2));
      expect(quad.isUsable, isTrue);
    });

    test('an empty mask has no page', () {
      final quad = quadFromMask(
        Uint8List(64 * 64),
        size: 64,
        frameWidth: 640,
        frameHeight: 640,
      );
      expect(quad, isNull);
    });

    test('a speck smaller than the page is rejected', () {
      final mask = Uint8List(64 * 64);
      mask[(20 * 64) + 20] = 1; // one pixel
      final quad = quadFromMask(
        mask,
        size: 64,
        frameWidth: 640,
        frameHeight: 640,
      );
      expect(quad, isNull);
    });

    test('the largest region wins over a stray blob', () {
      const size = 64;
      final mask = _rectangle(size, 8, 8, 56, 56); // the page
      // A small 4x4 blob elsewhere.
      for (var y = 2; y < 6; y++) {
        for (var x = 58; x < 62; x++) {
          mask[y * size + x] = 1;
        }
      }
      final quad = quadFromMask(
        mask,
        size: size,
        frameWidth: 640,
        frameHeight: 640,
      );
      expect(quad, isNotNull);
      // Corners follow the big region, not the 4x4 blob.
      expect(quad!.topLeft.x, closeTo(8 * 10.0, 2));
      expect(quad.bottomRight.x, closeTo(55 * 10.0, 2));
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
