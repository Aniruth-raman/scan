import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../design/lens_tokens.dart';
import '../services/scan_exporter.dart';

/// Review: the pages from one capture session with the two exports this app
/// supports — save to the device Gallery and export as a single PDF.
///
/// A session can hold several pages, so exports operate on the whole set.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.pages,
    required this.exporter,
  });

  final List<Uint8List> pages;
  final ScanExporter exporter;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController _titleController;
  late final PageController _pageController;
  bool _busy = false;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: ScanExporter.defaultTitle(DateTime.now()));
    _pageController = PageController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  String? get _title {
    final text = _titleController.text.trim();
    return text.isEmpty ? null : text;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveToGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var gallerySaved = 0;
      for (var i = 0; i < widget.pages.length; i++) {
        final title = widget.pages.length == 1
            ? _title
            : '${_title ?? ScanExporter.defaultTitle(DateTime.now())} '
                '(${i + 1} of ${widget.pages.length})';
        final entry = await widget.exporter.saveImage(
          widget.pages[i],
          title: title,
        );
        try {
          await Gal.putImage(entry.filePath, album: 'Lens Lite');
          gallerySaved++;
        } on GalException {
          // Saved to My Scans regardless; the gallery is best-effort.
        } on Exception {
          // Same as above.
        }
      }
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      final inGallery = gallerySaved == widget.pages.length;
      Navigator.pop(
        context,
        !inGallery
            ? 'Saved to My Scans'
            : widget.pages.length == 1
                ? 'Saved to Gallery'
                : 'Saved ${widget.pages.length} pages',
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not save: $error');
    }
  }

  Future<void> _exportPdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final entry = await widget.exporter
          .exportPdfPages(widget.pages, title: _title);
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(context, 'Exported PDF: ${entry.title}');
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not export: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final multiple = widget.pages.length > 1;

    return Scaffold(
      backgroundColor: LensColor.stageBlack,
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  SizedBox(
                    height: LensSize.editorBarHeight,
                    child: Row(
                      children: [
                        const SizedBox(width: LensSpace.xxs),
                        _BarAction(
                          icon: Icons.arrow_back,
                          label: 'Back',
                          onTap: () => Navigator.pop(context),
                        ),
                        const Spacer(),
                        if (multiple)
                          Padding(
                            padding: const EdgeInsets.only(right: LensSpace.md),
                            child: Text(
                              '${_index + 1} of ${widget.pages.length}',
                              style: const TextStyle(
                                color: LensColor.white70,
                                fontSize: LensType.label,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: widget.pages.length,
                      onPageChanged: (value) => setState(() => _index = value),
                      itemBuilder: (context, index) => InteractiveViewer(
                        maxScale: 6,
                        child: Center(
                          child: Image.memory(
                            widget.pages[index],
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Material(
            color: LensColor.gray0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                LensSpace.md,
                LensSpace.md,
                LensSpace.md,
                LensSpace.md + bottomInset,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: LensSpace.md),
                  Row(
                    children: [
                      Expanded(
                        child: _HeroAction(
                          label: 'Save to gallery',
                          icon: Icons.add_photo_alternate_outlined,
                          onTap: _busy ? null : _saveToGallery,
                          filled: true,
                        ),
                      ),
                      const SizedBox(width: LensSpace.xs),
                      Expanded(
                        child: _HeroAction(
                          label: 'Export PDF',
                          icon: Icons.picture_as_pdf_outlined,
                          onTap: _busy ? null : _exportPdf,
                          filled: false,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 40 dp hero pill, the app's only button shape.
class _HeroAction extends StatelessWidget {
  const _HeroAction({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.filled,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final background =
        filled ? LensColor.accent : LensColor.gray0;
    final foreground = filled ? LensColor.gray0 : LensColor.accent;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LensRadius.hero),
        child: Container(
          height: LensSize.heroHeight,
          decoration: BoxDecoration(
            color: enabled ? background : background.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(LensRadius.hero),
            border: filled
                ? null
                : Border.all(color: LensColor.accent, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: LensSize.iconSmall, color: foreground),
              const SizedBox(width: LensSpace.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: LensType.body,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: LensSize.touch,
        height: LensSize.touch,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Icon(icon, size: LensSize.icon, color: LensColor.gray0),
        ),
      ),
    );
  }
}
