import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/lens_tokens.dart';
import '../services/document_image_ops.dart';
import '../services/document_detector.dart';
import '../services/native_image_kit.dart';

/// Outcome of the crop stage.
///
/// [addAnother] is the filmstrip's dashed tile: commit this page and go
/// straight back to the viewfinder for the next one, without a round trip
/// through the session chrome.
@immutable
class AdjustResult {
  const AdjustResult(this.jpeg, {this.addAnother = false});

  final Uint8List jpeg;
  final bool addAnother;
}

/// Crop stage: corner adjustment with a live tone preview.
///
/// Geometry is measured from `lens-state4.png` and `crop_fragment_k2.xml`:
/// a 96 dp filmstrip band (`lenshvc_crop_carousel_container_size`) above a
/// 40 dp hero with 16 dp side and 12 dp vertical margins, and a 102 x 148 dp
/// translucent feature tray (`crop_feature_tray`, 8 dp from the right edge)
/// floating in the middle of the image.
class AdjustScreen extends StatefulWidget {
  const AdjustScreen({
    super.key,
    required this.originalJpeg,
    this.pages = const <Uint8List>[],
    this.filter = ScanFilter.none,
  });

  final Uint8List originalJpeg;

  /// Pages already committed to this session, newest last. Shown to the left
  /// of the page being cropped.
  final List<Uint8List> pages;

  /// Tone preset chosen by the capture mode; shown live and baked on commit.
  final ScanFilter filter;

  @override
  State<AdjustScreen> createState() => _AdjustScreenState();
}

class _AdjustScreenState extends State<AdjustScreen> {
  static const _trayWidth = 102.0;
  static const _trayRadius = 12.0;
  static const _trayFill = Color(0xD61C1C1C);

  Uint8List? _displayJpeg;
  int _imageWidth = 0;
  int _imageHeight = 0;
  DocumentQuad? _quad;
  DocumentQuad? _initialQuad;
  int _quarterTurns = 0;
  bool _working = true;
  bool _applying = false;
  String? _error;
  int? _dragIndex;

  /// Finger position in stage coordinates while a corner is being dragged; the
  /// loupe is anchored to it.
  Offset? _loupeAt;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final preview = await prepareAdjustPreview(widget.originalJpeg);
      if (!mounted) return;
      if (preview == null) {
        setState(() {
          _error = 'Could not read the captured image.';
          _working = false;
        });
        return;
      }
      final corners = preview.corners;
      final quad = DocumentQuad(
        topLeft: math.Point(corners[0], corners[1]),
        topRight: math.Point(corners[2], corners[3]),
        bottomRight: math.Point(corners[4], corners[5]),
        bottomLeft: math.Point(corners[6], corners[7]),
      );
      setState(() {
        _displayJpeg = preview.jpeg;
        _imageWidth = preview.width;
        _imageHeight = preview.height;
        _quad = quad;
        _initialQuad = quad;
        _working = false;
      });
    } catch (error) {
      debugPrint('Adjust prepare failed: $error');
      if (!mounted) return;
      setState(() {
        _error = 'Could not read the captured image.';
        _working = false;
      });
    }
  }

  // ------------------------------------------------------------ transforms --

  /// Display size in pixels: the page turned by [_quarterTurns] quarter turns.
  Size get _displaySize => _quarterTurns.isOdd
      ? Size(_imageHeight.toDouble(), _imageWidth.toDouble())
      : Size(_imageWidth.toDouble(), _imageHeight.toDouble());

  /// Image pixel -> display pixel, rotating [_quarterTurns] times clockwise.
  Offset _toDisplay(Offset point) {
    var x = point.dx;
    var y = point.dy;
    var w = _imageWidth.toDouble();
    var h = _imageHeight.toDouble();
    for (var i = 0; i < _quarterTurns; i++) {
      final nx = h - 1 - y;
      final ny = x;
      x = nx;
      y = ny;
      final swap = w;
      w = h;
      h = swap;
    }
    return Offset(x, y);
  }

  /// Display pixel -> image pixel (the inverse of [_toDisplay]).
  Offset _fromDisplay(Offset point) {
    var x = point.dx;
    var y = point.dy;
    var w = _displaySize.width;
    var h = _displaySize.height;
    for (var i = 0; i < _quarterTurns; i++) {
      final nx = y;
      final ny = w - 1 - x;
      x = nx;
      y = ny;
      final swap = w;
      w = h;
      h = swap;
    }
    return Offset(x, y);
  }

  /// Corners in the order the native warp expects for the current rotation.
  ///
  /// Rotating the page 90 degrees clockwise moves the old bottom-left corner
  /// into the top-left slot, so the quad is re-ordered rather than re-encoded:
  /// the warper always treats corner 0 as the output's top-left.
  List<math.Point<double>> _orderedCorners(DocumentQuad quad) {
    final corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft];
    final shift = _quarterTurns % 4;
    return [for (var i = 0; i < 4; i++) corners[(i - shift + 4) % 4]];
  }

  // --------------------------------------------------------------- actions --

  void _rotate() {
    if (_quad == null) return;
    HapticFeedback.selectionClick();
    setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
  }

  void _reset() {
    final initial = _initialQuad;
    if (initial == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _quad = initial;
      _quarterTurns = 0;
    });
  }

  Future<void> _apply({bool addAnother = false}) async {
    final quad = _quad;
    if (quad == null || _displayJpeg == null || _applying) return;

    if (_quarterTurns == 0 &&
        _isFullFrame(quad) &&
        widget.filter == ScanFilter.none) {
      // Nothing to crop, turn or tone: hand back the original capture.
      Navigator.pop(context, AdjustResult(widget.originalJpeg, addAnother: addAnother));
      return;
    }

    setState(() => _applying = true);
    try {
      final ordered = _orderedCorners(quad);
      final corners = <double>[
        for (final point in ordered) ...[point.x, point.y],
      ];
      // Crop from the original capture, not the display preview: corners are in
      // full-resolution coordinates and the page is rectified at that size.
      final cropped = await cropJpegToCorners(
        widget.originalJpeg,
        corners,
        fullWidth: _imageWidth,
        fullHeight: _imageHeight,
        filter: widget.filter,
      );
      if (!mounted) return;
      if (cropped == null) {
        setState(() => _applying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not crop the image.')),
        );
        return;
      }
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(context, AdjustResult(cropped, addAnother: addAnother));
    } catch (error) {
      debugPrint('Crop failed: $error');
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not crop the image: $error')),
      );
    }
  }

  bool _isFullFrame(DocumentQuad quad) {
    final w = _imageWidth - 1.0;
    final h = _imageHeight - 1.0;
    double dist(math.Point<double> a, math.Point<double> b) =>
        math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    return dist(quad.topLeft, math.Point(0, 0)) < 12 &&
        dist(quad.topRight, math.Point(w, 0)) < 12 &&
        dist(quad.bottomRight, math.Point(w, h)) < 12 &&
        dist(quad.bottomLeft, math.Point(0, h)) < 12;
  }

  // --------------------------------------------------------------- dragging --

  /// [origin] is the image's top-left in stage coordinates, so the loupe can be
  /// placed around the finger rather than around the image.
  void _selectCorner(Offset localPosition, Offset origin, double scale) {
    final quad = _quad;
    if (quad == null) return;
    final corners = quad.corners
        .map((point) => _toDisplay(Offset(point.x, point.y)) * scale)
        .toList();
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < corners.length; i++) {
      final distance = (corners[i] - localPosition).distanceSquared;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    _dragIndex = nearest;
    setState(() => _loupeAt = localPosition + origin);
  }

  void _dragTo(Offset localPosition, Offset origin, double scale) {
    final index = _dragIndex;
    final quad = _quad;
    if (index == null || quad == null) return;
    final imagePoint = _fromDisplay(localPosition / scale);
    final x = imagePoint.dx.clamp(0.0, (_imageWidth - 1).toDouble());
    final y = imagePoint.dy.clamp(0.0, (_imageHeight - 1).toDouble());
    final corners = [
      quad.topLeft,
      quad.topRight,
      quad.bottomRight,
      quad.bottomLeft,
    ];
    corners[index] = math.Point<double>(x, y);
    setState(() {
      _quad = DocumentQuad(
        topLeft: corners[0],
        topRight: corners[1],
        bottomRight: corners[2],
        bottomLeft: corners[3],
      );
      _loupeAt = localPosition + origin;
    });
  }

  void _endDrag() {
    _dragIndex = null;
    if (_loupeAt != null) setState(() => _loupeAt = null);
  }

  // ------------------------------------------------------------------ build --

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: LensColor.stageBlack,
        body: Stack(
          children: [
            Column(
              children: [
                SizedBox(height: padding.top),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildStage(),
                      _buildTopBand(),
                    ],
                  ),
                ),
                _buildBottomBand(),
                SizedBox(height: padding.bottom),
              ],
            ),
            // The tray is constrained to the parent in the original, so it
            // floats over the whole screen rather than the image area.
            _buildTray(),
          ],
        ),
      ),
    );
  }

  Widget _buildStage() {
    if (_working) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: LensColor.gray0),
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(LensSpace.lg),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: LensColor.white70, fontSize: LensType.body),
          ),
        ),
      );
    }
    final displayJpeg = _displayJpeg!;
    final quad = _quad!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final displaySize = _displaySize;
        final scale = math.min(
          constraints.maxWidth / displaySize.width,
          constraints.maxHeight / displaySize.height,
        );
        final width = displaySize.width * scale;
        final height = displaySize.height * scale;
        final left = (constraints.maxWidth - width) / 2;
        final top = (constraints.maxHeight - height) / 2;
        final corners = quad.corners
            .map((point) => _toDisplay(Offset(point.x, point.y)) * scale)
            .toList();

        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) => _selectCorner(
                  details.localPosition,
                  Offset(left, top),
                  scale,
                ),
                onPanUpdate: (details) => _dragTo(
                  details.localPosition,
                  Offset(left, top),
                  scale,
                ),
                onPanEnd: (_) {
                  HapticFeedback.selectionClick();
                  _endDrag();
                },
                onPanCancel: _endDrag,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColorFiltered(
                      colorFilter: ColorFilter.matrix(colorMatrixFor(widget.filter)),
                      child: RotatedBox(
                        quarterTurns: _quarterTurns,
                        child: Image.memory(
                          displayJpeg,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                    CustomPaint(painter: _CropPainter(corners: corners)),
                  ],
                ),
              ),
            ),
            if (_loupeAt != null) _buildLoupe(constraints, _loupeAt!),
          ],
        );
      },
    );
  }

  /// The loupe: an 80 dp circle (`lenshvc_crop_magnifier_diameter`) with a 2 dp
  /// white ring, floating above the finger so the corner is never under a thumb.
  ///
  /// `RawMagnifier` magnifies what is already painted beneath it, so the page,
  /// the quad and the corner grip are the same pixels at 2x — no second decode
  /// and no duplicated widget tree.
  Widget _buildLoupe(BoxConstraints constraints, Offset focal) {
    const diameter = LensSize.magnifier;
    const radius = diameter / 2;
    final preferred = focal + const Offset(0, -(radius + LensSize.magnifierGap));
    final centre = Offset(
      preferred.dx.clamp(radius + LensSpace.xs, constraints.maxWidth - radius - LensSpace.xs),
      preferred.dy.clamp(radius + LensSpace.xs, constraints.maxHeight - radius - LensSpace.xs),
    );
    return Positioned(
      left: centre.dx - radius,
      top: centre.dy - radius,
      child: RawMagnifier(
        size: const Size.square(diameter),
        magnificationScale: 2,
        decoration: MagnifierDecoration(
          shape: CircleBorder(
            side: BorderSide(
              color: LensColor.gray0,
              width: LensSize.magnifierBorder,
            ),
          ),
          shadows: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        // The magnifier reads the point this far from its own centre, which is
        // what keeps the content under the finger when the circle is clamped
        // against a screen edge.
        focalPointOffset: focal - centre,
      ),
    );
  }

  Widget _buildTopBand() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 63,
      child: Container(
        color: LensColor.black30,
        child: Stack(
          children: [
            Positioned(
              left: 2,
              top: 15,
              child: Semantics(
                button: true,
                label: 'Back to capture',
                child: SizedBox(
                  width: LensSize.touch,
                  height: LensSize.touch,
                  child: InkResponse(
                    radius: 24,
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.arrow_back,
                      size: LensSize.icon,
                      color: LensColor.gray0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Right-hand feature tray, centred on the screen like the original's
  /// `crop_feature_tray` (top and bottom constrained to the parent).
  Widget _buildTray() {
    return Positioned(
      right: LensSpace.xs,
      top: 0,
      bottom: 0,
      child: Align(
        alignment: const Alignment(0, -0.02),
        child: Container(
          width: _trayWidth,
          decoration: BoxDecoration(
            color: _trayFill,
            borderRadius: BorderRadius.circular(_trayRadius),
          ),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrayAction(
                label: 'Rotate',
                icon: Icons.rotate_right,
                onTap: _rotate,
              ),
              _TrayAction(
                label: 'Retake',
                icon: Icons.photo_camera_outlined,
                onTap: () => Navigator.pop(context),
              ),
              _TrayAction(
                label: 'Reset',
                icon: Icons.open_in_full,
                onTap: _reset,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBand() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: LensSpace.xs),
        const Text(
          'Crop document',
          style: TextStyle(
            fontSize: LensType.body,
            color: LensColor.gray3,
          ),
        ),
        const SizedBox(height: LensSpace.md),
        SizedBox(
          height: LensSize.filmThumbHeight,
          child: _buildFilmstrip(),
        ),
        const SizedBox(height: 26),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: LensSpace.md),
          child: _buildHero(),
        ),
        const SizedBox(height: LensSpace.sm),
      ],
    );
  }

  Widget _buildFilmstrip() {
    final displayJpeg = _displayJpeg;
    if (displayJpeg == null || _quad == null) {
      return const SizedBox.shrink();
    }
    const tileWidth = LensSize.filmThumbWidth;
    const gap = LensSpace.sm;
    final pages = widget.pages;
    return LayoutBuilder(
      builder: (context, constraints) {
        final currentLeft = constraints.maxWidth / 2 - tileWidth / 2;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Earlier pages of this session, newest nearest the current one.
            for (var i = 0; i < pages.length; i++)
              Positioned(
                left: currentLeft - (i + 1) * (tileWidth + gap),
                top: 0,
                child: _PageThumb(bytes: pages[pages.length - 1 - i]),
              ),
            Positioned(
              left: currentLeft,
              top: 0,
              child: _PageThumb(
                bytes: displayJpeg,
                selected: true,
                filter: widget.filter,
                quarterTurns: _quarterTurns,
              ),
            ),
            Positioned(
              left: currentLeft + tileWidth + gap,
              top: 0,
              child: _AddTile(onTap: _applying ? null : () => _apply(addAnother: true)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHero() {
    return Semantics(
      button: true,
      label: 'Review and edit',
      child: SizedBox(
        height: LensSize.heroHeight,
        child: Material(
          color: LensColor.accent,
          borderRadius: BorderRadius.circular(LensRadius.hero),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _applying ? null : () => _apply(),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _applying ? 'Preparing…' : 'Review and Edit',
                    style: const TextStyle(
                      fontSize: LensType.body,
                      fontWeight: FontWeight.w500,
                      color: LensColor.gray10,
                    ),
                  ),
                  const SizedBox(width: LensSpace.xs),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: LensColor.gray10,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the crop feature tray: right-aligned label, icon at the edge.
class _TrayAction extends StatelessWidget {
  const _TrayAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Stack(
            children: [
              Positioned(
                right: 48,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: LensType.body,
                      color: LensColor.gray0,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: LensSpace.sm,
                top: LensSpace.sm,
                child: Icon(icon, size: LensSize.icon, color: LensColor.gray0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Filmstrip page thumbnail: 52 x 68 dp slot, accent border when selected.
class _PageThumb extends StatelessWidget {
  const _PageThumb({
    required this.bytes,
    this.selected = false,
    this.filter,
    this.quarterTurns = 0,
  });

  final Uint8List bytes;
  final bool selected;
  final ScanFilter? filter;
  final int quarterTurns;

  @override
  Widget build(BuildContext context) {
    // Quarter turns swap the tile's axes, so the child is laid out landscape
    // and rotated back into the 52 x 68 slot.
    final swapped = quarterTurns.isOdd;
    Widget image = Image.memory(
      bytes,
      width: swapped ? LensSize.filmThumbHeight : LensSize.filmThumbWidth,
      height: swapped ? LensSize.filmThumbWidth : LensSize.filmThumbHeight,
      fit: BoxFit.cover,
      cacheWidth: 160,
      gaplessPlayback: true,
    );
    if (quarterTurns % 4 != 0) {
      image = RotatedBox(quarterTurns: quarterTurns % 4, child: image);
    }
    final tone = filter;
    if (tone != null && tone != ScanFilter.none) {
      image = ColorFiltered(
        colorFilter: ColorFilter.matrix(colorMatrixFor(tone)),
        child: image,
      );
    }
    return Container(
      width: LensSize.filmThumbWidth,
      height: LensSize.filmThumbHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LensRadius.hero),
        border: Border.all(
          color: selected ? LensColor.accent : Colors.transparent,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: image,
    );
  }
}

/// Dashed "capture another page" tile.
class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture another page',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: LensSize.filmThumbWidth,
          height: LensSize.filmThumbHeight,
          child: CustomPaint(
            painter: _DashedBorderPainter(
              radius: LensRadius.hero,
              color: LensColor.gray0.withValues(alpha: 0.55),
            ),
            child: const Center(
              child: Icon(
                Icons.add_photo_alternate_outlined,
                size: 24,
                color: LensColor.gray0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    for (final metric in outline.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + 6, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + 4;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.color != color;
}

/// White quad with corner grips and edge-midpoint pills, drawn crisp.
class _CropPainter extends CustomPainter {
  const _CropPainter({required this.corners});

  final List<Offset> corners;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final path = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..color = LensColor.gray0;
    canvas.drawPath(path, line);

    // Edge-midpoint pills: 33 x 3.5 dp, rotated onto their edge.
    final pill = Paint()..color = LensColor.gray0;
    for (var i = 0; i < 4; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % 4];
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      canvas.save();
      canvas.translate(mid.dx, mid.dy);
      canvas.rotate(math.atan2(b.dy - a.dy, b.dx - a.dx));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 33, height: 3.5),
          const Radius.circular(1.75),
        ),
        pill,
      );
      canvas.restore();
    }

    // Corner grips: 13 dp white discs.
    final grip = Paint()..color = LensColor.gray0;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x33000000);
    for (final corner in corners) {
      canvas.drawCircle(corner, 6.5, grip);
      canvas.drawCircle(corner, 6.5, edge);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) => oldDelegate.corners != corners;
}
