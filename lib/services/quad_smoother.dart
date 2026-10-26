import 'dart:math' as math;
import 'dart:ui' show Size;

import 'document_detector.dart';

/// Steadies the live document outline.
///
/// The detector answers every frame on its own, with no memory of the last one.
/// On a real desk that means the outline can hop between the page and whatever
/// else scored well a frame later — the "it keeps changing" feel.
///
/// So the drawn quad is filtered in two stages:
///
///  * **confirm** — a new outline only becomes the target once it repeats, i.e.
///    two consecutive detections agree within [tolerance]. Two candidates that
///    alternate frame by frame never agree with themselves, so neither becomes
///    the target and the outline holds still.
///  * **follow** — the drawn quad eases toward the target by [follow] per frame,
///    which turns small per-frame noise into a slow drift instead of a shake.
///
/// A short run of misses does not clear the outline ([releaseFrames]), so a
/// single dropped frame does not make it blink.
class QuadSmoother {
  QuadSmoother({
    this.follow = 0.4,
    this.tolerance = 0.08,
    this.confirmFrames = 2,
    this.releaseFrames = 5,
  });

  /// Fraction of the way the drawn quad moves toward its target each frame.
  final double follow;

  /// How far apart two detections may be and still count as the same outline,
  /// as a fraction of the frame diagonal.
  final double tolerance;

  /// Consecutive agreeing detections before a new outline is believed.
  final int confirmFrames;

  /// Misses tolerated before the outline is withdrawn.
  final int releaseFrames;

  DocumentQuad? _shown;
  DocumentQuad? _target;
  DocumentQuad? _pending;
  int _pendingFrames = 0;
  int _missed = 0;

  /// The quad to draw, or null when nothing is detected.
  DocumentQuad? get quad => _shown;

  /// Feeds one detection — null when the frame had no document — and returns
  /// the outline to draw now.
  DocumentQuad? update(DocumentQuad? detected, Size frame) {
    if (detected == null) {
      _missed++;
      if (_missed >= releaseFrames) _clear();
      return _shown;
    }
    _missed = 0;

    final shown = _shown;
    if (shown == null) {
      _shown = detected;
      _target = detected;
      _pending = null;
      _pendingFrames = 0;
      return _shown;
    }

    final tolerance = this.tolerance * _diagonal(frame);
    final aligned = _align(shown, detected);

    // Stage 1: agree on a target.
    final pending = _pending;
    _pendingFrames = pending != null && _distance(pending, aligned) <= tolerance
        ? _pendingFrames + 1
        : 1;
    _pending = aligned;
    if (_pendingFrames >= confirmFrames) {
      _target = aligned;
      _pending = null;
      _pendingFrames = 0;
    }

    // Stage 2: ease toward it.
    final target = _target ?? shown;
    _shown = _lerp(shown, target, follow);
    return _shown;
  }

  /// Drops the outline, e.g. when the camera is switched.
  void reset() => _clear();

  void _clear() {
    _shown = null;
    _target = null;
    _pending = null;
    _pendingFrames = 0;
    _missed = 0;
  }

  static double _diagonal(Size frame) =>
      math.sqrt(frame.width * frame.width + frame.height * frame.height);

  /// Re-orders [next]'s corners so index `i` lines up with `previous`'s index
  /// `i`. The detector always goes clockwise from the top-left, so a cyclic
  /// shift covers every mapping it can produce.
  static DocumentQuad _align(DocumentQuad previous, DocumentQuad next) {
    final from = previous.corners.toList();
    final to = next.corners.toList();
    var best = 0;
    var bestCost = double.infinity;
    for (var shift = 0; shift < 4; shift++) {
      var cost = 0.0;
      for (var i = 0; i < 4; i++) {
        final point = to[(i + shift) % 4];
        final anchor = from[i];
        cost +=
            (point.x - anchor.x) * (point.x - anchor.x) +
            (point.y - anchor.y) * (point.y - anchor.y);
      }
      if (cost < bestCost) {
        bestCost = cost;
        best = shift;
      }
    }
    return DocumentQuad(
      topLeft: to[best],
      topRight: to[(best + 1) % 4],
      bottomRight: to[(best + 2) % 4],
      bottomLeft: to[(best + 3) % 4],
    );
  }

  static double _distance(DocumentQuad a, DocumentQuad b) => a.distanceTo(b);

  static DocumentQuad _lerp(DocumentQuad from, DocumentQuad to, double t) {
    math.Point<double> mix(math.Point<double> a, math.Point<double> b) =>
        math.Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    return DocumentQuad(
      topLeft: mix(from.topLeft, to.topLeft),
      topRight: mix(from.topRight, to.topRight),
      bottomRight: mix(from.bottomRight, to.bottomRight),
      bottomLeft: mix(from.bottomLeft, to.bottomLeft),
    );
  }
}
