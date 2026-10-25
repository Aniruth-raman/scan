import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/edge_detection_worker.dart';
import '../services/edge_detector.dart';
import 'adjust_screen.dart';

/// Live capture screen with real-time document edge detection.
///
/// A luminance stream is analyzed in an isolate; while a document outline is
/// visible the preview is dimmed outside it and a "Document detected" chip
/// appears, mirroring the original's scanning affordance. Shutter leads into
/// the corner-adjust step, which mirrors the original's post-capture crop
/// flow.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _initializing = true;
  bool _capturing = false;
  bool _useFront = false;
  FlashMode _flash = FlashMode.off;
  String? _error;

  final EdgeDetectionWorker _detector = EdgeDetectionWorker();
  DocumentQuad? _quad;
  bool _analyzing = false;
  bool _wasDetecting = false;
  bool _streaming = false;

  bool get _detectEnabled => !_useFront;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _fail(String message) {
    final controller = _controller;
    _controller = null;
    _streaming = false;
    controller?.dispose();
    if (!mounted) return;
    setState(() {
      _error = message;
      _initializing = false;
    });
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras()
          .timeout(const Duration(seconds: 15));
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'No camera available on this device.';
          _initializing = false;
        });
        return;
      }
      final wanted =
          _useFront ? CameraLensDirection.front : CameraLensDirection.back;
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == wanted,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      _controller = controller;
      await controller.initialize().timeout(const Duration(seconds: 15));
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      if (!_detector.isReady) {
        await _detector.start();
      }
      await _resumeStream();
      if (!mounted) return;
      setState(() {
        _error = null;
        _initializing = false;
      });
    } on CameraException catch (exception) {
      _fail(exception.description ?? exception.code);
    } catch (error) {
      _fail('Camera could not start: $error');
    }
  }

  Future<void> _resumeStream() async {
    final controller = _controller;
    if (controller == null || !_detectEnabled || _streaming) return;
    try {
      await controller.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      // Detection is best-effort; capture still works without the stream.
      _streaming = false;
    }
  }

  Future<void> _pauseStream() async {
    if (!_streaming) return;
    _streaming = false;
    try {
      await _controller?.stopImageStream();
    } on CameraException {
      // Already stopped or unsupported; nothing to do.
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_analyzing || !_detectEnabled || _capturing) return;
    final yPlane = image.planes.first;
    if (yPlane.bytes.isEmpty) return;
    _analyzing = true;
    final frameWidth = image.width;
    final frameHeight = image.height;
    try {
      final rotation = _controller?.description.sensorOrientation ?? 90;
      final quad = await _detector.detect(
        luminance: Uint8List.fromList(yPlane.bytes),
        width: frameWidth,
        height: frameHeight,
        bytesPerRow: yPlane.bytesPerRow,
        rotationDegrees: rotation,
      );
      if (!mounted) return;
      final rotated = rotation == 90 || rotation == 270;
      setState(() {
        _quad = quad;
        _frameDisplaySize = Size(
          (rotated ? frameHeight : frameWidth).toDouble(),
          (rotated ? frameWidth : frameHeight).toDouble(),
        );
      });
      if (quad != null && !_wasDetecting) {
        await HapticFeedback.selectionClick();
      }
      _wasDetecting = quad != null;
    } finally {
      _analyzing = false;
    }
  }

  Size _frameDisplaySize = Size.zero;

  Future<void> _switchCamera() async {
    if (_initializing) return;
    setState(() {
      _useFront = !_useFront;
      _initializing = true;
      _quad = null;
      _wasDetecting = false;
    });
    await _pauseStream();
    final old = _controller;
    _controller = null;
    await old?.dispose();
    await _start();
  }

  Future<void> _cycleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    setState(() => _flash = next);
    await _controller?.setFlashMode(next);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      await _pauseStream();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      final adjusted = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(
          builder: (_) => AdjustScreen(originalJpeg: bytes),
          fullscreenDialog: false,
        ),
      );
      if (!mounted) return;
      if (adjusted == null) {
        // User cancelled the crop step; resume the live camera.
        setState(() => _capturing = false);
        await _resumeStream();
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, adjusted);
    } on CameraException catch (exception) {
      if (!mounted) return;
      setState(() => _capturing = false);
      await _resumeStream();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Capture failed: ${exception.description ?? exception.code}',
          ),
        ),
      );
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        _ => Icons.flash_off,
      };

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              const Text(
                'Camera Service error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Close other camera apps and try again. If the problem '
                'persists, restart your device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _initializing = true;
                  });
                  _start();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (_initializing || controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final aspect = _frameDisplaySize == Size.zero
        ? controller.value.aspectRatio
        : _frameDisplaySize.aspectRatio;
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 250),
                  opacity: _quad == null ? 0 : 1,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _QuadOverlayPainter(
                        quad: _quad,
                        displaySize: _frameDisplaySize,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Detection chip.
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: _quad == null
                  ? Container(
                      key: const ValueKey('searching-chip'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.center_focus_weak,
                              color: Colors.white70, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Looking for a document',
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Container(
                      key: const ValueKey('detected-chip'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.document_scanner,
                              color: Colors.white, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Document detected',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, color: Colors.white, size: 30),
            tooltip: 'Cancel',
          ),
        ),
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                onPressed: _cycleFlash,
                icon: Icon(_flashIcon, color: Colors.white, size: 30),
                tooltip: 'Flash mode',
              ),
              _ShutterButton(onPressed: _capture, busy: _capturing),
              IconButton(
                onPressed: _switchCamera,
                icon: const Icon(
                  Icons.cameraswitch,
                  color: Colors.white,
                  size: 30,
                ),
                tooltip: 'Switch camera',
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _detector.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _buildBody()),
    );
  }
}

class _QuadOverlayPainter extends CustomPainter {
  _QuadOverlayPainter({required this.quad, required this.displaySize});

  final DocumentQuad? quad;
  final Size displaySize;

  @override
  void paint(Canvas canvas, Size size) {
    final documentQuad = quad;
    if (documentQuad == null || displaySize == Size.zero) return;

    final sx = size.width / displaySize.width;
    final sy = size.height / displaySize.height;
    Offset offset(math.Point<double> point) =>
        Offset(point.x * sx, point.y * sy);

    final path = Path()
      ..moveTo(offset(documentQuad.topLeft).dx, offset(documentQuad.topLeft).dy)
      ..lineTo(
          offset(documentQuad.topRight).dx, offset(documentQuad.topRight).dy)
      ..lineTo(offset(documentQuad.bottomRight).dx,
          offset(documentQuad.bottomRight).dy)
      ..lineTo(offset(documentQuad.bottomLeft).dx,
          offset(documentQuad.bottomLeft).dy)
      ..close();

    // Dim everything outside the document.
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(path, Offset.zero);
    canvas.drawPath(
      dim,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill,
    );

    // Glow + crisp outline.
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Corner accents.
    final dotPaint = Paint()..color = Colors.white;
    for (final corner in documentQuad.corners) {
      canvas.drawCircle(offset(corner), 5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_QuadOverlayPainter oldDelegate) =>
      oldDelegate.quad != quad || oldDelegate.displaySize != displaySize;
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onPressed, required this.busy});

  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
          color: busy ? Colors.white24 : Colors.transparent,
        ),
        child: busy
            ? const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              )
            : const Icon(Icons.camera, color: Colors.white, size: 40),
      ),
    );
  }
}