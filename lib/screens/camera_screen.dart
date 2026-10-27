import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/scan_tokens.dart';
import '../services/document_detection_worker.dart';
import '../services/document_detector.dart';
import '../services/native_image_kit.dart';
import '../services/quad_smoother.dart';
import '../services/scan_exporter.dart';
import 'adjust_screen.dart';
import 'review_screen.dart';

/// Capture stage: black chrome, live edge detection, and a session filmstrip.
///
/// Geometry measured on the 384 x 832 dp reference viewport:
/// 48 dp targets 12 dp in from the top corners, a vertical two-slot tray at the
/// right, a 68 dp shutter ring, a 46 dp mode carousel and an 82 dp filmstrip
/// sitting 24 dp above the ring.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.exporter});

  /// Owns storage and history; the session hands pages straight to review.
  final ScanExporter exporter;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

/// Capture modes. Each maps onto a tone preset rather than a fake label.
enum _CaptureMode {
  scan('SCAN', 'Scan', ScanFilter.none),
  whiteboard('WHITEBOARD', 'Whiteboard', ScanFilter.blackAndWhite),
  businessCard('BUSINESS CARD', 'Business card', ScanFilter.enhance);

  const _CaptureMode(this.label, this.semanticLabel, this.filter);

  final String label;
  final String semanticLabel;
  final ScanFilter filter;
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _initializing = true;
  bool _capturing = false;
  bool _useFront = false;
  FlashMode _flash = FlashMode.off;
  String? _error;
  _CaptureMode _mode = _CaptureMode.scan;

  final DocumentDetectionWorker _detector = DocumentDetectionWorker.instance;
  final QuadSmoother _smoother = QuadSmoother();
  DocumentQuad? _quad;
  bool _analyzing = false;
  bool _wasDetecting = false;
  bool _streaming = false;
  Size _frameDisplaySize = Size.zero;

  /// Pages captured in this session, already cropped.
  final List<Uint8List> _pages = <Uint8List>[];

  /// Scan captures on its own once a document has held still; the shutter still
  /// works as a manual override.
  bool _autoCapture = true;

  /// When the current outline started holding still, or null while it moves.
  DateTime? _steadySince;

  /// How long the outline has to hold before the shot is taken.
  static const _steadyHold = Duration(milliseconds: 900);

  /// How far the outline may drift between frames and still count as still,
  /// as a fraction of the frame diagonal.
  static const _steadyDrift = 0.006;

  bool _moreOpen = false;

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
      final cameras = await availableCameras().timeout(
        const Duration(seconds: 15),
      );
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'No camera available on this device.';
          _initializing = false;
        });
        return;
      }
      final wanted = _useFront
          ? CameraLensDirection.front
          : CameraLensDirection.back;
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == wanted,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        description,
        // Documents need pixels: `high` is 720p, which throws most of the
        // sensor away. Capture at the largest size the device offers.
        ResolutionPreset.max,
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
      // Already stopped or unsupported.
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_analyzing || !_detectEnabled || _capturing) return;
    final yPlane = image.planes.first;
    if (yPlane.bytes.isEmpty) return;
    _analyzing = true;
    try {
      final rotation = _controller?.description.sensorOrientation ?? 90;
      final quad = await _detector.detectLuma(
        luminance: Uint8List.fromList(yPlane.bytes),
        width: image.width,
        height: image.height,
        bytesPerRow: yPlane.bytesPerRow,
        rotationDegrees: rotation,
      );
      if (!mounted) return;
      final rotated = rotation == 90 || rotation == 270;
      final frame = Size(
        (rotated ? image.height : image.width).toDouble(),
        (rotated ? image.width : image.height).toDouble(),
      );
      // The detector has no memory of the previous frame; the smoother does, so
      // the outline stops hopping between competing candidates.
      final previous = _quad;
      final smoothed = _smoother.update(quad, frame);
      setState(() {
        _quad = smoothed;
        _frameDisplaySize = frame;
      });
      if (smoothed != null && !_wasDetecting) {
        HapticFeedback.selectionClick();
      }
      _wasDetecting = smoothed != null;
      _trackSteadiness(previous, smoothed, frame);
    } finally {
      _analyzing = false;
    }
  }

  /// Watches the smoothed outline and fires the shutter once it holds still.
  ///
  /// Steadiness is measured on the *drawn* quad, so the hold only starts when
  /// the easing has converged — a document being moved keeps resetting it.
  void _trackSteadiness(
    DocumentQuad? previous,
    DocumentQuad? current,
    Size frame,
  ) {
    if (!_autoCapture ||
        _capturing ||
        _moreOpen ||
        current == null ||
        previous == null ||
        !current.isUsable) {
      _steadySince = null;
      return;
    }
    final diagonal = math.sqrt(
      frame.width * frame.width + frame.height * frame.height,
    );
    if (current.distanceTo(previous) > diagonal * _steadyDrift) {
      _steadySince = null;
      return;
    }
    final since = _steadySince ??= DateTime.now();
    if (DateTime.now().difference(since) >= _steadyHold) {
      _steadySince = null;
      _capture();
    }
  }

  Future<void> _switchCamera() async {
    if (_initializing) return;
    setState(() {
      _useFront = !_useFront;
      _initializing = true;
      _quad = null;
      _wasDetecting = false;
    });
    _smoother.reset();
    _steadySince = null;
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
    // Whatever was holding still is stale the moment the shot is taken.
    _steadySince = null;
    // Keep the outline that was on screen: it is the crop's starting corners.
    final shotQuad = _quad;
    final shotFrame = _frameDisplaySize;
    setState(() => _capturing = true);
    try {
      await _pauseStream();
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      final outline = (shotQuad == null ||
              shotFrame.width <= 0 ||
              shotFrame.height <= 0)
          ? null
          : <double>[
              shotQuad.topLeft.x / shotFrame.width,
              shotQuad.topLeft.y / shotFrame.height,
              shotQuad.topRight.x / shotFrame.width,
              shotQuad.topRight.y / shotFrame.height,
              shotQuad.bottomRight.x / shotFrame.width,
              shotQuad.bottomRight.y / shotFrame.height,
              shotQuad.bottomLeft.x / shotFrame.width,
              shotQuad.bottomLeft.y / shotFrame.height,
            ];
      final cropped = await Navigator.push<AdjustResult>(
        context,
        MaterialPageRoute(
          builder: (_) => AdjustScreen(
            originalJpeg: bytes,
            pages: List<Uint8List>.unmodifiable(_pages),
            filter: _mode.filter,
            normalizedCorners: outline,
            frameSize: shotFrame,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _capturing = false;
        if (cropped != null) _pages.add(cropped.jpeg);
      });
      if (cropped?.addAnother ?? false) {
        // "Add page" on the crop stage: keep the session going and shoot the
        // next page straight away instead of dropping back to the chrome.
        await _capture();
        return;
      }
      if (cropped != null) {
        // "Review and Edit" commits the page and lands on the review stage,
        // the way the original chains crop into review.
        await _review();
        return;
      }
      await _resumeStream();
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

  Future<void> _close() async {
    await _pauseStream();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _review() async {
    if (_pages.isEmpty) return;
    await _pauseStream();
    if (!mounted) return;
    final pages = List<Uint8List>.unmodifiable(_pages);
    final result = await Navigator.push<ReviewResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(pages: pages, exporter: widget.exporter),
      ),
    );
    if (!mounted) return;
    if (result == null) {
      await _resumeStream();
      return;
    }
    if (result.addMore) {
      // "Add" hands the edited pages back, so the filmstrip keeps them while
      // the session keeps shooting.
      setState(() {
        _pages
          ..clear()
          ..addAll(result.pages);
      });
      await _resumeStream();
      return;
    }
    // The session was exported; hand the message back to My Scans.
    Navigator.pop(context, result.message);
  }

  IconData get _flashIcon => switch (_flash) {
    FlashMode.auto => Icons.flash_auto,
    FlashMode.always => Icons.flash_on,
    _ => Icons.flash_off,
  };

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final topInset = padding.top;
    final bottomInset = padding.bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: ScanColor.stageBlack,
        // The preview does not bleed under the system bars. The status bar
        // is a solid black band, the preview stops at the filmstrip, and the
        // shutter/carousel band below it is black as well.
        body: Column(
          children: [
            SizedBox(height: topInset),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [_buildStage(), _buildTopChrome()],
              ),
            ),
            _buildBottomChrome(bottomInset),
          ],
        ),
      ),
    );
  }

  Widget _buildStage() {
    final error = _error;
    if (error != null) return _buildError(error);

    final controller = _controller;
    if (_initializing ||
        controller == null ||
        !controller.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: ScanColor.gray0,
          ),
        ),
      );
    }

    final preview = controller.value.previewSize;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final w = preview == null
        ? 1.0
        : (portrait ? preview.height : preview.width).toDouble();
    final h = preview == null
        ? 1.0
        : (portrait ? preview.width : preview.height).toDouble();

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(controller),
              IgnorePointer(
                child: AnimatedOpacity(
                  duration: ScanMotion.base,
                  curve: ScanMotion.curve,
                  opacity: _quad == null ? 0 : 1,
                  child: CustomPaint(
                    painter: _QuadOutlinePainter(
                      quad: _quad,
                      frameSize: _frameDisplaySize,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ScanSpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: ScanColor.white70,
              size: 48,
            ),
            const SizedBox(height: ScanSpace.sm),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                color: ScanColor.gray0,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: ScanSpace.xs),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: ScanColor.gray6, fontSize: 12),
            ),
            const SizedBox(height: ScanSpace.md),
            FilledButton.tonal(
              onPressed: () {
                setState(() {
                  _error = null;
                  _initializing = true;
                });
                _start();
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  /// Chevron and feature tray float over the top of the preview. Measured:
  /// dismiss target at 19.6 dp from the left and 15.8 dp below the status bar;
  /// tray at 11.7 dp from the right and 11.7 dp below the status bar.
  Widget _buildTopChrome() {
    return Stack(
      children: [
        Positioned(
          left: ScanSpace.md + ScanSpace.xxs,
          top: ScanSpace.md,
          child: _BarGlyph(
            icon: Icons.chevron_left,
            label: 'Back to My Scans',
            size: 32,
            onTap: _close,
          ),
        ),
        Positioned(
          right: ScanSpace.sm,
          top: ScanSpace.sm,
          child: _ToolTray(
            flashIcon: _flashIcon,
            flashLabel: switch (_flash) {
              FlashMode.auto => 'Flash auto',
              FlashMode.always => 'Flash on',
              _ => 'Flash off',
            },
            onFlash: _cycleFlash,
            onMore: _showMore,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: ScanSpace.sm,
          child: Center(child: _buildAutoCaptureHint()),
        ),
      ],
    );
  }

  /// The auto-capture hint, floating just above the filmstrip.
  ///
  /// The original shows the same two states in a rounded pill
  /// ( 12 dp, 8 dp radius) and a
  /// 1 dp progress line () for the
  /// hold before the shot.
  Widget _buildAutoCaptureHint() {
    final holding = _steadySince != null;
    final String? label;
    if (!_autoCapture || _initializing || _error != null) {
      label = null;
    } else if (_quad == null) {
      label = 'Looking for a document';
    } else if (holding) {
      label = 'Hold steady';
    } else {
      label = 'Document found';
    }

    final progress = holding
        ? (DateTime.now().difference(_steadySince!).inMilliseconds /
                  _steadyHold.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    return AnimatedSwitcher(
      duration: ScanMotion.base,
      child: label == null
          ? const SizedBox.shrink()
          : Container(
              key: ValueKey<String>(label),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: ScanColor.black30,
                borderRadius: BorderRadius.circular(ScanRadius.hero),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: ScanType.label,
                      color: ScanColor.gray0,
                    ),
                  ),
                  if (holding) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 72,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(0.5),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 1,
                          backgroundColor: ScanColor.white70.withValues(
                            alpha: 0.3,
                          ),
                          color: ScanColor.accent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  /// Black band under the preview: session filmstrip, shutter, mode carousel.
  ///
  /// The filmstrip only exists once a page is captured, so the preview grows
  /// into the space and the band animates in on the first shot.
  Widget _buildBottomChrome(double bottomInset) {
    return AnimatedSize(
      duration: ScanMotion.base,
      curve: ScanMotion.curve,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pages.isNotEmpty) _Filmstrip(pages: _pages, onTap: _review),
          const SizedBox(height: ScanSpace.lg),
          _CaptureRing(busy: _capturing, onTap: _capture),
          _ModeCarousel(
            selected: _mode,
            onSelected: (mode) => setState(() => _mode = mode),
          ),
          SizedBox(height: bottomInset),
        ],
      ),
    );
  }

  Future<void> _showMore() async {
    _moreOpen = true;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ScanColor.gray10,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          // Scrollable so a short sheet box clamps instead of overflowing.
          child: ListView(
            shrinkWrap: true,
            children: [
              SwitchListTile(
                secondary: Icon(
                  _autoCapture
                      ? Icons.motion_photos_on_outlined
                      : Icons.motion_photos_off_outlined,
                  color: ScanColor.gray0,
                ),
                title: const Text(
                  'Auto capture',
                  style: TextStyle(color: ScanColor.gray0),
                ),
                subtitle: const Text(
                  'Take the shot once the page holds still',
                  style: TextStyle(
                    color: ScanColor.gray6,
                    fontSize: ScanType.label,
                  ),
                ),
                value: _autoCapture,
                activeThumbColor: ScanColor.accent,
                onChanged: (value) {
                  setSheetState(() {});
                  setState(() {
                    _autoCapture = value;
                    _steadySince = null;
                  });
                },
              ),
              _SheetAction(
                icon: Icons.cameraswitch_outlined,
                label: 'Switch camera',
                onTap: () => Navigator.pop(sheetContext, 'switch'),
              ),
              _SheetAction(
                icon: _pages.isEmpty
                    ? Icons.document_scanner_outlined
                    : Icons.edit_note,
                label: _pages.isEmpty ? 'Multi-page scanning' : 'Review pages',
                onTap: () => Navigator.pop(sheetContext, 'review'),
              ),
            ],
          ),
        ),
      ),
    );
    _moreOpen = false;
    if (!mounted || action == null) return;
    switch (action) {
      case 'switch':
        await _switchCamera();
      case 'review':
        await _review();
    }
  }
}

/// The 68 dp shutter: a 6 dp white ring with a clear centre.
class _CaptureRing extends StatefulWidget {
  const _CaptureRing({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  State<_CaptureRing> createState() => _CaptureRingState();
}

class _CaptureRingState extends State<_CaptureRing> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1,
          duration: ScanMotion.fast,
          curve: ScanMotion.curve,
          child: SizedBox(
            width: ScanSize.captureRing,
            height: ScanSize.captureRing,
            child: widget.busy
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: ScanColor.gray0,
                    ),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ScanColor.gray0,
                        width: ScanSize.captureStroke,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Vertical two-slot tray at the top right.
class _ToolTray extends StatelessWidget {
  const _ToolTray({
    required this.flashIcon,
    required this.flashLabel,
    required this.onFlash,
    required this.onMore,
  });

  final IconData flashIcon;
  final String flashLabel;
  final VoidCallback onFlash;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ScanColor.trayFill,
        borderRadius: BorderRadius.circular(ScanRadius.tray),
        border: Border.all(color: ScanColor.trayStroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BarGlyph(
            icon: flashIcon,
            label: flashLabel,
            onTap: onFlash,
            size: ScanSize.icon,
          ),
          _BarGlyph(
            icon: Icons.more_vert,
            label: 'More options',
            onTap: onMore,
            size: ScanSize.icon,
          ),
        ],
      ),
    );
  }
}

class _BarGlyph extends StatelessWidget {
  const _BarGlyph({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = ScanSize.icon,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: ScanSize.touch,
        height: ScanSize.touch,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Icon(icon, size: size, color: ScanColor.gray0),
        ),
      ),
    );
  }
}

/// Uppercase, tracked mode carousel - the signature type cue.
class _ModeCarousel extends StatelessWidget {
  const _ModeCarousel({required this.selected, required this.onSelected});

  final _CaptureMode selected;
  final ValueChanged<_CaptureMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          //  keeps the first and last label clear
          // of the import button and the camera switcher.
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _CaptureMode.values.length; i++) ...[
                if (i > 0) const SizedBox(width: ScanSpace.xxs),
                _CarouselLabel(
                  mode: _CaptureMode.values[i],
                  selected: _CaptureMode.values[i] == selected,
                  onTap: () => onSelected(_CaptureMode.values[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One carousel label: 8 dp side padding with a 4 dp gap between items, which
/// is what the measured item boxes add up to.
class _CarouselLabel extends StatelessWidget {
  const _CarouselLabel({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final _CaptureMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${mode.semanticLabel} mode',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ScanSpace.xs),
          child: Center(
            // Selection eases instead of snapping: the carousel is the stage's
            // main type cue, so it carries the state change.
            child: AnimatedDefaultTextStyle(
              duration: ScanMotion.fast,
              curve: ScanMotion.curve,
              style: TextStyle(
                fontSize: ScanType.label,
                letterSpacing: ScanType.carouselTracking,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? ScanColor.gray0 : ScanColor.gray6,
              ),
              child: Text(mode.label),
            ),
          ),
        ),
      ),
    );
  }
}

/// Captured pages for this session.
///
/// Measured mini-gallery strip: 86 x 82 dp tiles butted together, full bleed,
/// 82 dp band directly above the shutter gap.
class _Filmstrip extends StatelessWidget {
  const _Filmstrip({required this.pages, required this.onTap});

  final List<Uint8List> pages;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: pages.length,
        itemBuilder: (context, index) {
          return Semantics(
            button: true,
            label: 'Page ${index + 1} of ${pages.length}. Review pages.',
            child: GestureDetector(
              onTap: onTap,
              child: SizedBox(
                width: 86,
                height: 82,
                child: Image.memory(
                  pages[index],
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: ScanColor.gray0),
      title: Text(label, style: const TextStyle(color: ScanColor.gray0)),
      onTap: onTap,
    );
  }
}

/// Orange document outline, drawn in the same space as the detector's frame.
class _QuadOutlinePainter extends CustomPainter {
  _QuadOutlinePainter({required this.quad, required this.frameSize});

  final DocumentQuad? quad;
  final Size frameSize;

  @override
  void paint(Canvas canvas, Size size) {
    final documentQuad = quad;
    if (documentQuad == null || frameSize == Size.zero) return;

    // Map the analysed frame onto the widget with BoxFit.cover.
    final scale = math.max(
      size.width / frameSize.width,
      size.height / frameSize.height,
    );
    final dx = (size.width - frameSize.width * scale) / 2;
    final dy = (size.height - frameSize.height * scale) / 2;
    Offset map(math.Point<double> point) =>
        Offset(point.x * scale + dx, point.y * scale + dy);

    final path = Path()
      ..moveTo(map(documentQuad.topLeft).dx, map(documentQuad.topLeft).dy)
      ..lineTo(map(documentQuad.topRight).dx, map(documentQuad.topRight).dy)
      ..lineTo(
        map(documentQuad.bottomRight).dx,
        map(documentQuad.bottomRight).dy,
      )
      ..lineTo(map(documentQuad.bottomLeft).dx, map(documentQuad.bottomLeft).dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = ScanColor.accentLight,
    );
  }

  @override
  bool shouldRepaint(_QuadOutlinePainter oldDelegate) =>
      oldDelegate.quad != quad || oldDelegate.frameSize != frameSize;
}
