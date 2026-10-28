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

  group('prepareYuvInput', () {
    // The live frame is inset into the model input; sample inside that area.
    const inset = documentModelInputSize ~/ 5;
    const innerSide = documentModelInputSize - 2 * inset;
    int inner(int row, int column) =>
        ((row + inset) * documentModelInputSize + column + inset) * 3;

    Uint8List plane(int length, int value) =>
        Uint8List(length)..fillRange(0, length, value);

    test('neutral chroma keeps the page colourless', () {
      final input = prepareYuvInput(
        y: plane(4 * 2, 235),
        u: plane(2, 128),
        v: plane(2, 128),
        width: 4,
        height: 2,
        yRowStride: 4,
        uvRowStride: 2,
        uvPixelStride: 1,
        rotationDegrees: 0,
      );
      // Undo the normalisation: neutral chroma means all three channels hold
      // the same grey, straight from luma.
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];
      double raw(int channel) =>
          input[inner(10, 10) + channel] * std[channel] + mean[channel];
      expect(raw(0), closeTo(raw(1), 1e-6));
      expect(raw(0), closeTo(raw(2), 1e-6));
      expect(raw(0), closeTo(235 / 255, 1e-6));
    });

    test('chroma reaches the model instead of being dropped', () {
      final input = prepareYuvInput(
        y: plane(4, 200),
        u: plane(1, 90),
        v: plane(1, 200),
        width: 2,
        height: 2,
        yRowStride: 2,
        uvRowStride: 1,
        uvPixelStride: 1,
        rotationDegrees: 0,
      );
      // High Cr and low Cb make the red channel the brightest.
      final at = inner(10, 10);
      expect(input[at], greaterThan(input[at + 2]));
    });

    test('a quarter turn puts the sensor column on the display top row', () {
      // 2x4 sensor, left column white on a black page.
      final y = Uint8List(2 * 4);
      for (var row = 0; row < 4; row++) {
        y[row * 2] = 235;
      }
      final chroma = plane(2, 128);
      final input = prepareYuvInput(
        y: y,
        u: chroma,
        v: chroma,
        width: 2,
        height: 4,
        yRowStride: 2,
        uvRowStride: 1,
        uvPixelStride: 1,
        rotationDegrees: 90,
      );
      final lastRow = documentModelInputSize - 2 * inset - 1;
      expect(input[inner(0, 10)], greaterThan(input[inner(lastRow, 10)]));
    });

    test('every model pixel averages its sensor block, not a point sample', () {
      // A 1-pixel checkerboard at two sensor pixels per model pixel: only
      // averaging can make that grey, and averaging is what keeps live sensor
      // grain out of the model.
      const side = innerSide * 2;
      final y = Uint8List(side * side);
      for (var row = 0; row < side; row++) {
        for (var column = 0; column < side; column++) {
          y[row * side + column] = (row + column).isEven ? 255 : 0;
        }
      }
      final chroma = plane((side ~/ 2) * (side ~/ 2), 128);
      final input = prepareYuvInput(
        y: y,
        u: chroma,
        v: chroma,
        width: side,
        height: side,
        yRowStride: side,
        uvRowStride: side ~/ 2,
        uvPixelStride: 1,
        rotationDegrees: 0,
      );
      // Undo the normalisation: the block average is mid grey, not black/white.
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];
      final value = input[inner(10, 10)] * std[0] + mean[0];
      expect(value, closeTo(127.5 / 255, 0.01));
    });

    test('a dim frame is stretched towards the light of a real photo', () {
      // Half the frame at 60, half at 90: a dim room, as the live feed arrives.
      const side = documentModelInputSize * 2;
      final y = Uint8List(side * side);
      for (var row = 0; row < side; row++) {
        for (var column = 0; column < side; column++) {
          y[row * side + column] = column < side ~/ 2 ? 60 : 90;
        }
      }
      final chroma = plane((side ~/ 2) * (side ~/ 2), 128);
      final input = prepareYuvInput(
        y: y,
        u: chroma,
        v: chroma,
        width: side,
        height: side,
        yRowStride: side,
        uvRowStride: side ~/ 2,
        uvPixelStride: 1,
        rotationDegrees: 0,
      );
      const mean = [0.485, 0.456, 0.406];
      const std = [0.229, 0.224, 0.225];
      // The bright half now reaches white, the dark half the black point.
      final bright = input[inner(100, 140)] * std[0] + mean[0];
      final dark = input[inner(100, 10)] * std[0] + mean[0];
      expect(bright, closeTo(1.0, 0.02));
      expect(dark, closeTo(0.0, 0.02));
    });
    test('a mask that fills the inset input maps back to the whole frame', () {
      const size = 64;
      final mask = Uint8List(size * size)..fillRange(0, size * size, 1);
      final quad = quadFromMask(
        mask,
        size: size,
        frameWidth: 640,
        frameHeight: 480,
        inset: 8,
      );
      expect(quad, isNotNull);
      // The synthetic border is not part of the frame, so corners clamp to it.
      expect(quad!.topLeft.x, 0);
      expect(quad.topLeft.y, 0);
      expect(quad.bottomRight.x, closeTo(639, 1));
      expect(quad.bottomRight.y, closeTo(479, 1));
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
