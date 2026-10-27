import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:scan/services/document_image_ops.dart';

void main() {
  const frame = Size(400, 300);

  test('the live outline is mapped onto the capture resolution', () {
    // A page filling the middle half of the preview frame.
    const outline = <double>[0.25, 0.25, 0.75, 0.25, 0.75, 0.75, 0.25, 0.75];

    final corners = cornersFromOutline(outline, frame, 4000, 3000);

    expect(corners, <double>[1000, 750, 3000, 750, 3000, 2250, 1000, 2250]);
  });

  test('no outline falls back to detection', () {
    expect(cornersFromOutline(null, frame, 4000, 3000), isNull);
  });

  test('a malformed outline falls back to detection', () {
    expect(cornersFromOutline(<double>[0.1, 0.2], frame, 4000, 3000), isNull);
  });

  test('a different preview and capture aspect keeps the page in place', () {
    // 4:3 preview, 16:9 capture: cover-mapping centres the smaller frame
    // vertically instead of stretching the outline across the whole page.
    final corners = cornersFromOutline(
      const <double>[0.25, 0.25, 0.75, 0.25, 0.75, 0.75, 0.25, 0.75],
      const Size(400, 300),
      1920,
      1080,
    );
    expect(corners, isNotNull);
    // scale = 4.8, dy = -180: 0.25 * 300 * 4.8 - 180 = 180.
    expect(corners![1], closeTo(180, 0.001));
    expect(corners[3], closeTo(180, 0.001));
  });

  test('corners are clamped inside the capture', () {
    final corners = cornersFromOutline(
      const <double>[-0.5, -0.5, 1.5, -0.5, 1.5, 1.5, -0.5, 1.5],
      frame,
      4000,
      3000,
    );
    expect(corners, isNotNull);
    expect(corners![0], 0);
    expect(corners[1], 0);
    expect(corners[2], 3999);
    expect(corners[3], 0);
  });
}
