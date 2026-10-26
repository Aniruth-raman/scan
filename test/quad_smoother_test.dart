import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:lens_lite/services/document_detector.dart';
import 'package:lens_lite/services/quad_smoother.dart';

/// A 480 x 640 frame, so the diagonal is 800 and `tolerance` of 0.08 is 64 px.
const frame = Size(480, 640);

DocumentQuad quad({
  double left = 100,
  double top = 150,
  double width = 280,
  double height = 340,
}) => DocumentQuad(
  topLeft: math.Point(left, top),
  topRight: math.Point(left + width, top),
  bottomRight: math.Point(left + width, top + height),
  bottomLeft: math.Point(left, top + height),
);

double corner(QuadSmoother smoother, int index) =>
    smoother.quad!.corners.toList()[index].x;

void main() {
  test('the first detection is drawn immediately', () {
    final smoother = QuadSmoother();
    final first = quad();
    expect(smoother.update(first, frame), same(first));
  });

  test('small movements are eased toward, not snapped to', () {
    final smoother = QuadSmoother();
    smoother.update(quad(), frame);

    // 20 px of drift per frame: inside the tolerance, so it is followed.
    final moved = quad(left: 120);
    for (var i = 0; i < 20; i++) {
      smoother.update(moved, frame);
    }

    // Converged on the new outline without ever jumping to it.
    expect(smoother.quad!.topLeft.x, closeTo(120, 1));
  });

  test('two alternating outlines leave the drawn quad where it is', () {
    final smoother = QuadSmoother();
    final a = quad();
    final b = quad(left: 300, width: 120);
    smoother.update(a, frame);
    final settled = smoother.quad!.topLeft.x;

    // The detector flips between two very different candidates every frame.
    for (var i = 0; i < 30; i++) {
      smoother.update(i.isEven ? b : a, frame);
    }

    // Neither candidate is ever confirmed twice in a row, so nothing moves.
    expect(smoother.quad!.topLeft.x, closeTo(settled, 1));
  });

  test('a different outline is adopted once it repeats', () {
    final smoother = QuadSmoother();
    smoother.update(quad(), frame);

    final other = quad(left: 300, width: 120);
    smoother.update(other, frame);
    // One sighting is not enough.
    expect(smoother.quad!.topLeft.x, lessThan(200));

    for (var i = 0; i < 12; i++) {
      smoother.update(other, frame);
    }
    expect(smoother.quad!.topLeft.x, closeTo(300, 2));
  });

  test('a single dropped frame does not clear the outline', () {
    final smoother = QuadSmoother();
    smoother.update(quad(), frame);

    expect(smoother.update(null, frame), isNotNull);
    expect(smoother.update(null, frame), isNotNull);
    expect(smoother.update(null, frame), isNotNull);
    expect(smoother.update(null, frame), isNotNull);
  });

  test('a sustained miss withdraws the outline', () {
    final smoother = QuadSmoother(releaseFrames: 3);
    smoother.update(quad(), frame);

    smoother.update(null, frame);
    smoother.update(null, frame);
    expect(smoother.quad, isNotNull);
    expect(smoother.update(null, frame), isNull);
  });

  test('a rotated corner list is matched, not jumped to', () {
    final smoother = QuadSmoother(confirmFrames: 2);
    final base = quad();
    smoother.update(base, frame);

    // The very same rectangle, but reported starting from the top-right.
    final shifted = DocumentQuad(
      topLeft: base.topRight,
      topRight: base.bottomRight,
      bottomRight: base.bottomLeft,
      bottomLeft: base.topLeft,
    );
    smoother.update(shifted, frame);

    // Alignment means "identical", so the drawn quad must not jump a side.
    expect(corner(smoother, 0), closeTo(base.topLeft.x, 1));
    expect(corner(smoother, 0), lessThan(200));
  });

  test('reset forgets the outline', () {
    final smoother = QuadSmoother();
    smoother.update(quad(), frame);
    smoother.reset();
    expect(smoother.quad, isNull);
  });
}
