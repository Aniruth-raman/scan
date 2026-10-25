import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lens_lite/services/document_detector.dart';

/// Splits an edge into [count] short segments, the way M-LSD reports a straight
/// border as many small pieces that the merge step has to collapse back into
/// one line.
List<Segment> _edge(
  math.Point<double> from,
  math.Point<double> to, {
  int count = 5,
}) {
  final segments = <Segment>[];
  for (var i = 0; i < count; i++) {
    final t0 = i / count;
    final t1 = (i + 1) / count;
    segments.add(
      Segment(
        from.x + (to.x - from.x) * t0,
        from.y + (to.y - from.y) * t0,
        from.x + (to.x - from.x) * t1,
        from.y + (to.y - from.y) * t1,
      ),
    );
  }
  return segments;
}

/// A page seen slightly in perspective, inside a 512 px reference frame.
const _topLeft = math.Point<double>(96, 72);
const _topRight = math.Point<double>(410, 104);
const _bottomRight = math.Point<double>(392, 430);
const _bottomLeft = math.Point<double>(80, 398);

List<Segment> _pageEdgeSegments() => [
      ..._edge(_topLeft, _topRight),
      ..._edge(_topRight, _bottomRight),
      ..._edge(_bottomRight, _bottomLeft),
      ..._edge(_bottomLeft, _topLeft),
    ];

void main() {
  group('detectQuadFromSegments', () {
    test('recovers the four corners of a skewed page', () {
      final quad = detectQuadFromSegments(
        _pageEdgeSegments(),
        frameWidth: 512,
        frameHeight: 512,
      );

      expect(quad, isNotNull, reason: 'four clean borders should fit a quad');
      final corners = quad!.corners.toList();
      const expected = [_topLeft, _topRight, _bottomRight, _bottomLeft];
      for (var i = 0; i < 4; i++) {
        final dx = corners[i].x - expected[i].x;
        final dy = corners[i].y - expected[i].y;
        expect(
          math.sqrt(dx * dx + dy * dy),
          lessThan(6),
          reason: 'corner $i should land on the page corner',
        );
      }
    });

    test('scales the quad onto the requested frame', () {
      final quad = detectQuadFromSegments(
        _pageEdgeSegments(),
        frameWidth: 1024,
        frameHeight: 768,
      );

      expect(quad, isNotNull);
      // 512-wide reference space maps onto the frame's width and height.
      expect(quad!.topLeft.x, closeTo(_topLeft.x * 2, 12));
      expect(quad.topLeft.y, closeTo(_topLeft.y * 1.5, 9));
    });

    test('keeps corner order clockwise from top-left', () {
      final quad = detectQuadFromSegments(
        _pageEdgeSegments(),
        frameWidth: 512,
        frameHeight: 512,
      )!;

      expect(quad.topLeft.x, lessThan(quad.topRight.x));
      expect(quad.topRight.y, lessThan(quad.bottomRight.y));
      expect(quad.bottomLeft.x, lessThan(quad.bottomRight.x));
      expect(quad.topLeft.y, lessThan(quad.bottomLeft.y));
    });

    test('needs at least four segments', () {
      final quad = detectQuadFromSegments(
        _pageEdgeSegments().take(3).toList(),
        frameWidth: 512,
        frameHeight: 512,
      );
      expect(quad, isNull);
    });

    test('rejects a document that only spans a sliver of the frame', () {
      final tiny = <Segment>[
        ..._edge(
          const math.Point<double>(10, 10),
          const math.Point<double>(60, 10),
          count: 2,
        ),
        ..._edge(
          const math.Point<double>(60, 10),
          const math.Point<double>(60, 50),
          count: 2,
        ),
        ..._edge(
          const math.Point<double>(60, 50),
          const math.Point<double>(10, 50),
          count: 2,
        ),
        ..._edge(
          const math.Point<double>(10, 50),
          const math.Point<double>(10, 10),
          count: 2,
        ),
      ];

      final quad = detectQuadFromSegments(
        tiny,
        frameWidth: 512,
        frameHeight: 512,
      );
      expect(quad, isNull, reason: 'below the minimum area fraction');
    });

    test('ignores scattered segments with no closed outline', () {
      final noise = <Segment>[
        const Segment(20, 20, 60, 24),
        const Segment(300, 40, 340, 46),
        const Segment(120, 300, 160, 330),
        const Segment(400, 380, 430, 410),
        const Segment(200, 200, 230, 210),
        const Segment(60, 420, 90, 430),
      ];
      expect(
        detectQuadFromSegments(noise, frameWidth: 512, frameHeight: 512),
        isNull,
      );
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
  });
}
