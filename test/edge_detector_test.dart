import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/services/edge_detector.dart';

Uint8List grayPlane({
  required int width,
  required int height,
  required bool Function(int x, int y) isDocument,
}) {
  final y = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      y[col + row * width] = isDocument(col, row) ? 235 : 25;
    }
  }
  return y;
}

math.Point<double> point(double x, double y) => math.Point<double>(x, y);

void main() {
  test('detects an upright document rectangle', () {
    final y = grayPlane(
      width: 120,
      height: 200,
      isDocument: (x, y) => x >= 20 && x < 100 && y >= 30 && y < 170,
    );

    final quad = EdgeDetector.detectInPlane(y, width: 120, height: 200);

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, closeTo(20, 6));
    expect(quad.topLeft.y, closeTo(30, 6));
    expect(quad.topRight.x, closeTo(99, 6));
    expect(quad.topRight.y, closeTo(30, 6));
    expect(quad.bottomRight.x, closeTo(99, 6));
    expect(quad.bottomRight.y, closeTo(169, 6));
    expect(quad.bottomLeft.x, closeTo(20, 6));
    expect(quad.bottomLeft.y, closeTo(169, 6));
  });

  test('maps a 90-degree sensor frame into display coordinates', () {
    // Sensor is landscape 240x160; display is portrait 160x240.
    // sensor(x, y) -> display(159 - y, x).
    final y = grayPlane(
      width: 240,
      height: 160,
      isDocument: (x, y) => x >= 40 && x < 200 && y >= 30 && y < 130,
    );

    final quad =
        EdgeDetector.detectInPlane(y, width: 240, height: 160, rotationDegrees: 90);

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, closeTo(30, 6));
    expect(quad.topLeft.y, closeTo(40, 6));
    expect(quad.topRight.x, closeTo(129, 6));
    expect(quad.topRight.y, closeTo(40, 6));
    expect(quad.bottomRight.x, closeTo(129, 6));
    expect(quad.bottomRight.y, closeTo(199, 6));
    expect(quad.bottomLeft.x, closeTo(30, 6));
    expect(quad.bottomLeft.y, closeTo(199, 6));
  });

  test('returns null when the scene has no document-like region', () {
    final allDark =
        grayPlane(width: 100, height: 100, isDocument: (_, _) => false);
    expect(EdgeDetector.detectInPlane(allDark, width: 100, height: 100),
        isNull);

    final allBright =
        grayPlane(width: 100, height: 100, isDocument: (_, _) => true);
    expect(EdgeDetector.detectInPlane(allBright, width: 100, height: 100),
        isNull);
  });

  test('detects inside decoded images (display orientation)', () {
    final image = img.Image(width: 160, height: 240);
    img.fillRect(
      image,
      x1: 30,
      y1: 40,
      x2: 129,
      y2: 199,
      color: img.ColorRgb8(235, 235, 235),
    );

    final quad = EdgeDetector.detectInImage(image);

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, closeTo(30, 6));
    expect(quad.bottomRight.y, closeTo(199, 6));
  });

  test('perspective crop returns a rectangle matching the quad', () {
    final image = img.Image(width: 200, height: 300);
    img.fillRect(
      image,
      x1: 40,
      y1: 60,
      x2: 159,
      y2: 239,
      color: img.ColorRgb8(240, 240, 240),
    );
    final quad = DocumentQuad(
      topLeft: point(40, 60),
      topRight: point(159, 60),
      bottomRight: point(159, 239),
      bottomLeft: point(40, 239),
    );

    final cropped = EdgeDetector.cropToQuad(image, quad);

    expect(cropped.width, inInclusiveRange(116, 122));
    expect(cropped.height, inInclusiveRange(176, 182));
    final center =
        cropped.getPixel(cropped.width ~/ 2, cropped.height ~/ 2);
    expect(center.luminanceNormalized, greaterThan(0.8));
  });
}