import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/document_image_ops.dart';
import '../services/edge_detector.dart';
import '../services/native_image_kit.dart';

/// Post-capture corner adjustment, mirroring the original's flow:
/// the detected document corners are pre-filled and can be dragged before
/// the perspective crop is applied. Pops the final JPEG bytes, or the
/// untouched original via "Use full image".
class AdjustScreen extends StatefulWidget {
  const AdjustScreen({
    super.key,
    required this.originalJpeg,
    this.filter = ScanFilter.none,
  });

  final Uint8List originalJpeg;

  /// Tone preset chosen by the capture mode; baked in when the page is rendered.
  final ScanFilter filter;

  @override
  State<AdjustScreen> createState() => _AdjustScreenState();
}

class _AdjustScreenState extends State<AdjustScreen> {
  Uint8List? _displayJpeg;
  int _imageWidth = 0;
  int _imageHeight = 0;
  DocumentQuad? _quad;
  bool _working = true;
  bool _applying = false;
  String? _error;

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
      setState(() {
        _displayJpeg = preview.jpeg;
        _imageWidth = preview.width;
        _imageHeight = preview.height;
        _quad = DocumentQuad(
          topLeft: math.Point(corners[0], corners[1]),
          topRight: math.Point(corners[2], corners[3]),
          bottomRight: math.Point(corners[4], corners[5]),
          bottomLeft: math.Point(corners[6], corners[7]),
        );
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

  Future<void> _apply() async {
    final quad = _quad;
    if (quad == null || _displayJpeg == null || _applying) return;

    final isFullFrame = _isFullFrame(quad);
    if (isFullFrame && widget.filter == ScanFilter.none) {
      // Nothing to crop and no tone to bake; hand back the original capture.
      Navigator.pop(context, widget.originalJpeg);
      return;
    }

    setState(() => _applying = true);
    try {
      final corners = <double>[
        quad.topLeft.x,
        quad.topLeft.y,
        quad.topRight.x,
        quad.topRight.y,
        quad.bottomRight.x,
        quad.bottomRight.y,
        quad.bottomLeft.x,
        quad.bottomLeft.y,
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
      Navigator.pop(context, cropped);
    } catch (error) {
      debugPrint('Crop failed: $error');
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not crop the image: $error')),
      );
    }
  }

  /// Confirms before discarding the capture, matching the original's retake
  /// prompt.
  Future<void> _retake() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: const Text(
          'Going back will delete this photo. Do you want to retake it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Retake'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context);
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

  void _selectCorner(Offset localPosition) {
    final quad = _quad;
    if (quad == null) return;
    final corners = quad.corners.toList();
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < corners.length; i++) {
      final distance = (Offset(corners[i].x, corners[i].y) - localPosition)
          .distanceSquared;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    _dragIndex = nearest;
  }

  int? _dragIndex;

  void _dragTo(Offset localPosition) {
    final index = _dragIndex;
    final quad = _quad;
    if (index == null || quad == null) return;
    final x = localPosition.dx.clamp(0.0, (_imageWidth - 1).toDouble());
    final y = localPosition.dy.clamp(0.0, (_imageHeight - 1).toDouble());
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _retake,
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: 'Retake',
                  ),
                  const Expanded(
                    child: Text(
                      'Crop',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _retake,
                    child: const Text(
                      'Retake',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Center(child: _buildCanvas())),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    if (_working) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    final displayJpeg = _displayJpeg!;
    final quad = _quad!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageWidth = _imageWidth.toDouble();
        final imageHeight = _imageHeight.toDouble();
        final scale = math.min(
          constraints.maxWidth / imageWidth,
          constraints.maxHeight / imageHeight,
        );
        final width = imageWidth * scale;
        final height = imageHeight * scale;
        final left = (constraints.maxWidth - width) / 2;
        final top = (constraints.maxHeight - height) / 2;

        final corners = quad.corners
            .map((point) => Offset(point.x * scale, point.y * scale))
            .toList();
        const handleRadius = 16.0;

        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: GestureDetector(
                onPanDown: (details) => _selectCorner(details.localPosition),
                onPanUpdate: (details) => _dragTo(details.localPosition),
                onPanEnd: (_) => HapticFeedback.selectionClick(),
                behavior: HitTestBehavior.opaque,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Image.memory(
                      displayJpeg,
                      width: width,
                      height: height,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _AdjustPainter(
                          corners: corners,
                          scale: scale,
                        ),
                      ),
                    ),
                    for (final corner in corners)
                      Positioned(
                        left: corner.dx - handleRadius,
                        top: corner.dy - handleRadius,
                        child: Container(
                          width: handleRadius * 2,
                          height: handleRadius * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final canApply = _quad != null && !_working && _error == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: canApply && !_applying
                ? () => Navigator.pop(context, widget.originalJpeg)
                : null,
            icon: const Icon(Icons.crop_original),
            label: const Text('Full image'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: canApply && !_applying ? _apply : null,
            icon: _applying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _AdjustPainter extends CustomPainter {
  _AdjustPainter({required this.corners, required this.scale});

  final List<Offset> corners;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final path = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();

    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(path, Offset.zero);
    canvas.drawPath(
      dim,
      Paint()..color = Colors.black.withValues(alpha: 0.4),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_AdjustPainter oldDelegate) =>
      oldDelegate.corners != corners || oldDelegate.scale != scale;
}