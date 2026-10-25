import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../design/lens_tokens.dart';
import '../services/native_image_kit.dart';
import '../services/scan_exporter.dart';
import 'adjust_screen.dart';

/// One page of the review session: the pixels the crop stage committed, plus
/// the edits layered on top of them.
///
/// Rotation and tone stay as state rather than being baked on every tap, so
/// switching a tone re-renders from the original instead of stacking JPEG
/// generations. [NativeImageKit.transform] bakes them once, at save time.
class _Page {
  _Page(this.bytes, {this.filter = ScanFilter.none, this.turns = 0});

  Uint8List bytes;
  ScanFilter filter;
  int turns;
}

/// What the review stage hands back to the capture session.
///
/// Either the session was exported — [message] is a snackbar for My Scans — or
/// the user asked for another page, and the pages go back to the camera so the
/// filmstrip keeps what was already edited.
@immutable
class ReviewResult {
  const ReviewResult.exported(this.message)
      : addMore = false,
        pages = const <Uint8List>[];

  const ReviewResult.addMore(this.pages)
      : addMore = true,
        message = null;

  final bool addMore;
  final String? message;
  final List<Uint8List> pages;
}

/// Review & Edit: the captured pages, per-page editing, and the export.
///
/// Geometry is measured from `ui-edit.xml` and `postcapture_collection_view_k2.xml`
/// on the 384 x 832 dp reference viewport:
///
///  - 48 dp top bar (`guideline_top_margin`): 48 dp back target at 12 dp, and
///    "Options" flush to the end edge at 14 sp / 16 dp padding.
///  - pager inset 16 dp, vertically centred.
///  - feature tray 48 x 193 dp, 12 dp from the end edge, centred on the content
///    column (`topFeatureTrayContainer` is constrained top and bottom).
///  - bottom navigation: 12 dp padding, a 58 dp action row of three 120 dp
///    cells, then a 48 dp container holding the 344 x 40 dp Finish pill.
///
/// Unlike the earlier build this stage is black, not white: the original's root
/// is `@color/lenshvc_black` and `lens-state5.png` shows black chrome.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.pages,
    required this.exporter,
  });

  /// Pages from the capture session, newest last.
  final List<Uint8List> pages;
  final ScanExporter exporter;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final PageController _pageController;
  late final List<_Page> _pages;
  late String _title;

  int _index = 0;
  bool _busy = false;
  bool _saveImage = true;
  bool _savePdf = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pages = widget.pages.map(_Page.new).toList();
    _title = ScanExporter.defaultTitle(DateTime.now());
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  _Page get _current => _pages[_index];

  // --------------------------------------------------------------- actions --

  /// Bakes both edits into every page, once.
  Future<List<Uint8List>> _bake() async {
    final baked = <Uint8List>[];
    for (final page in _pages) {
      baked.add(
        page.filter == ScanFilter.none && page.turns == 0
            ? page.bytes
            : await NativeImageKit.transform(
                page.bytes,
                quarterTurns: page.turns,
                filter: page.filter,
              ),
      );
    }
    return baked;
  }

  void _rotate() {
    HapticFeedback.selectionClick();
    setState(() => _current.turns = (_current.turns + 1) % 4);
  }

  void _deletePage() {
    if (_pages.length < 2) return;
    // Haptics are feedback, not control flow: the page goes without waiting.
    HapticFeedback.mediumImpact();
    setState(() {
      _pages.removeAt(_index);
      _index = _index.clamp(0, _pages.length - 1);
    });
    _pageController.jumpToPage(_index);
  }

  Future<void> _recrop() async {
    final result = await Navigator.push<AdjustResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AdjustScreen(
          originalJpeg: _current.bytes,
          filter: _current.filter,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.addAnother) {
      await _addPages();
      return;
    }
    setState(() {
      // The crop stage already rectified, turned and toned the page, so the
      // review-stage edits start from zero again.
      _current
        ..bytes = result.jpeg
        ..filter = ScanFilter.none
        ..turns = 0;
    });
  }

  Future<void> _addPages() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final pages = await _bake();
      if (!mounted) return;
      Navigator.pop(context, ReviewResult.addMore(pages));
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not prepare the pages: $error');
    }
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final pages = await _bake();
      final parts = <String>[];
      // Nothing ticked would otherwise save nothing at all; an image is the
      // default the capture stage has always done.
      final saveImage = _saveImage || !_savePdf;

      if (saveImage) {
        // `Gal.putImage` does nothing when gallery access is refused, so ask
        // once and only claim the gallery when it is actually granted.
        var inGallery = await _hasGalleryAccess();
        for (var i = 0; i < pages.length; i++) {
          final title = pages.length == 1
              ? _title
              : '$_title (${i + 1} of ${pages.length})';
          final entry = await widget.exporter.saveImage(pages[i], title: title);
          if (!inGallery) continue;
          try {
            await Gal.putImage(entry.filePath, album: 'Lens Lite');
          } catch (_) {
            // Saved to My Scans regardless; the gallery is best-effort.
            inGallery = false;
          }
        }
        parts.add(
          !inGallery
              ? 'Saved to My Scans'
              : pages.length == 1
                  ? 'Saved to Gallery'
                  : 'Saved ${pages.length} pages',
        );
      }

      if (_savePdf) {
        final entry = await widget.exporter.exportPdfPages(pages, title: _title);
        parts.add('PDF: ${entry.title}');
      }

      HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(context, ReviewResult.exported(parts.join(' · ')));
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not save: $error');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _hasGalleryAccess() async {
    try {
      return await Gal.hasAccess();
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- sheets --

  Future<void> _openOptions() async {
    await _openSheet<void>(
      (sheetContext, controller) => _OptionsSheet(
        scrollController: controller,
        title: _title,
        image: _saveImage,
        pdf: _savePdf,
        onImage: (value) => _saveImage = value,
        onPdf: (value) => _savePdf = value,
        onRename: _rename,
      ),
    );
  }

  /// Renames the document. Returns null when the dialog was dismissed.
  Future<String?> _rename() async {
    final controller = TextEditingController(text: _title);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Scan name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return null;
    _title = name;
    return name;
  }

  Future<void> _pickFilter() async {
    final chosen = await _openSheet<ScanFilter>(
      (sheetContext, controller) =>
          _FilterSheet(scrollController: controller, selected: _current.filter),
      // All four presets visible without dragging: a chooser that hides half
      // its options is worse than a taller sheet.
      peek: 240,
    );
    if (chosen == null || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() => _current.filter = chosen);
  }

  Future<void> _reorder() async {
    final order = await _openSheet<List<_Page>>(
      (sheetContext, controller) => _ReorderSheet(
        scrollController: controller,
        pages: List<_Page>.of(_pages),
      ),
    );
    if (order == null || !mounted) return;
    setState(() {
      _pages
        ..clear()
        ..addAll(order);
      _index = _index.clamp(0, _pages.length - 1);
    });
    _pageController.jumpToPage(_index);
  }

  /// Every review sheet is the same white drawer: 16 dp top corners, a
  /// 36 x 4 dp handle, a 20 sp header, and a 160 dp peek
  /// (`lenshvc_bottomsheet_peak_height` on the reference viewport) that expands
  /// to 90 % of the screen when dragged.
  ///
  /// The peek is measured above the system navigation bar, the way the original
  /// measures it from its own window bottom.
  Future<T?> _openSheet<T>(
    Widget Function(BuildContext, ScrollController) builder, {
    double peek = LensSize.sheetPeek,
  }) {
    final media = MediaQuery.of(context);
    // The modal sheet's box excludes the top safe area; the peek has to be a
    // fraction of *that*, not of the raw screen height.
    final available = media.size.height - media.padding.top;
    final inset = media.viewPadding.bottom;
    final fraction = ((peek + inset) / available).clamp(0.1, 0.9);
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: LensColor.gray0,
      elevation: 0,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(LensRadius.tray)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: fraction,
        minChildSize: fraction,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, controller) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: builder(context, controller),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- build --

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
        body: Column(
          children: [
            SizedBox(height: padding.top),
            Expanded(
              child: Stack(
                children: [
                  Column(
                    children: [
                      _buildTopBar(),
                      Expanded(child: _buildPager()),
                      _buildBottomBar(),
                    ],
                  ),
                  _buildTray(),
                ],
              ),
            ),
            SizedBox(height: padding.bottom),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: LensSize.editorBarHeight,
      child: Stack(
        children: [
          Positioned(
            left: LensSpace.sm,
            top: 0,
            bottom: 0,
            child: Center(
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
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Semantics(
                button: true,
                label: 'Options',
                child: InkWell(
                  onTap: _busy ? null : _openOptions,
                  // `lenshvc_pill_button_text_size` + 16 dp / 5.5 dp padding,
                  // flush to the end edge exactly as measured.
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: LensSpace.md,
                      vertical: 5.5,
                    ),
                    child: Text(
                      'Options',
                      style: TextStyle(
                        fontSize: LensType.body,
                        color: LensColor.editorText,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPager() {
    return PageView.builder(
      controller: _pageController,
      itemCount: _pages.length,
      onPageChanged: (value) => setState(() => _index = value),
      itemBuilder: (context, index) {
        final page = _pages[index];
        return InteractiveViewer(
          maxScale: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: LensSpace.md),
            child: Center(
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(colorMatrixFor(page.filter)),
                child: RotatedBox(
                  quarterTurns: page.turns,
                  child: Image.memory(
                    page.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Four 48 dp slots, 12 dp in from the end edge, centred on the content
  /// column above the bottom bar.
  Widget _buildTray() {
    return Positioned(
      right: LensSpace.sm,
      top: 0,
      bottom: 0,
      child: Center(
        // A plain DecoratedBox: a Container with a border would inflate the
        // 48 x 192 dp plate by the 1 dp stroke.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: LensColor.editorTrayFill,
            borderRadius: BorderRadius.circular(LensRadius.tray),
            border: Border.all(color: LensColor.trayStroke),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrayAction(
                icon: Icons.crop,
                label: 'Crop',
                onTap: _busy ? null : _recrop,
              ),
              _TrayAction(
                icon: Icons.rotate_right,
                label: 'Rotate',
                onTap: _busy ? null : _rotate,
              ),
              _TrayAction(
                icon: Icons.delete_outline,
                label: 'Delete page',
                onTap: _busy || _pages.length < 2 ? null : _deletePage,
              ),
              _TrayAction(
                icon: Icons.more_vert,
                label: 'More options',
                onTap: _busy ? null : _openOptions,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.all(LensSize.editorNavPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: LensSize.actionRow,
            child: Row(
              children: [
                _ActionCell(
                  icon: Icons.filter_vintage_outlined,
                  label: 'Filters',
                  onTap: _busy ? null : _pickFilter,
                ),
                _ActionCell(
                  icon: Icons.swap_horiz,
                  label: 'Reorder',
                  onTap: _busy || _pages.length < 2 ? null : _reorder,
                ),
                _ActionCell(
                  icon: Icons.add_photo_alternate_outlined,
                  label: 'Add',
                  onTap: _busy ? null : _addPages,
                ),
              ],
            ),
          ),
          const SizedBox(height: LensSpace.xs),
          SizedBox(
            height: LensSize.touch,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: LensSpace.xs),
              child: Center(
                child: SizedBox(
                  height: LensSize.heroHeight,
                  child: Semantics(
                    button: true,
                    enabled: !_busy,
                    label: 'Finish',
                    child: Material(
                      color: _busy ? LensColor.disabled : LensColor.accent,
                      borderRadius: BorderRadius.circular(LensRadius.hero),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _busy ? null : _finish,
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: LensColor.gray11,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.check,
                                      size: LensSize.icon,
                                      color: LensColor.gray11,
                                    ),
                              const SizedBox(width: LensSpace.xs),
                              Text(
                                _busy ? 'Saving…' : 'Finish',
                                style: const TextStyle(
                                  fontSize: LensType.body,
                                  fontWeight: FontWeight.w500,
                                  color: LensColor.gray11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: LensSpace.xs),
        ],
      ),
    );
  }
}

/// One 48 dp slot of the vertical feature tray: 24 dp glyph, no label — the
/// original collapses the tray's labels in the editor, unlike in crop.
class _TrayAction extends StatelessWidget {
  const _TrayAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: SizedBox(
        width: LensSize.editorTrayWidth,
        height: 48,
        child: InkResponse(
          onTap: onTap,
          child: Icon(
            icon,
            size: LensSize.icon,
            color: enabled ? LensColor.gray0 : LensColor.gray0.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }
}

/// One cell of the 58 dp action row: a 48 dp target holding a 24 dp glyph and a
/// 12 sp label, 10 dp from the top and 8 dp apart.
class _ActionCell extends StatelessWidget {
  const _ActionCell({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final tint = enabled ? LensColor.editorIcon : LensColor.editorDisabled;
    return Expanded(
      child: Center(
        child: Semantics(
          button: true,
          enabled: enabled,
          label: label,
          child: SizedBox(
            width: LensSize.touch,
            height: LensSize.actionRow,
            child: InkResponse(
              onTap: onTap,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Icon(icon, size: LensSize.icon, color: tint),
                  const SizedBox(height: LensSpace.xs),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: LensType.label,
                      color: enabled ? LensColor.editorText : LensColor.editorDisabled,
                      height: 1,
                    ),
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

/// 36 x 4 dp handle above every sheet header.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: LensSpace.sm,
      child: Center(
        child: SizedBox(
          width: LensSize.sheetHandleWidth,
          height: LensSize.sheetHandleHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: LensColor.sheetHandle,
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section header band: 12 sp on #F2F2F2, 16 dp inset.
class _SheetSection extends StatelessWidget {
  const _SheetSection(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: LensColor.sheetBand,
      padding: const EdgeInsets.fromLTRB(LensSpace.md, LensSpace.xs, LensSpace.md, LensSpace.xs),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: LensType.label,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
          color: LensColor.sheetHeader,
        ),
      ),
    );
  }
}

/// Where the pages go: an image in the gallery, a PDF, or both.
class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({
    required this.scrollController,
    required this.title,
    required this.image,
    required this.pdf,
    required this.onImage,
    required this.onPdf,
    required this.onRename,
  });

  final ScrollController scrollController;
  final String title;
  final bool image;
  final bool pdf;
  final ValueChanged<bool> onImage;
  final ValueChanged<bool> onPdf;
  final Future<String?> Function() onRename;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late bool _image = widget.image;
  late bool _pdf = widget.pdf;
  late String _title = widget.title;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.zero,
      children: [
        const _SheetHandle(),
        const Padding(
          padding: EdgeInsets.fromLTRB(
            LensSpace.md,
            LensSpace.xs,
            LensSpace.md,
            LensSpace.xs,
          ),
          child: Text(
            'Options',
            style: TextStyle(
              fontSize: LensType.sheet,
              fontWeight: FontWeight.w500,
              color: LensColor.gray10,
            ),
          ),
        ),
        const _SheetSection('TITLE'),
        InkWell(
          onTap: () async {
            final name = await widget.onRename();
            if (name != null && mounted) setState(() => _title = name);
          },
          child: Padding(
            padding: const EdgeInsets.all(LensSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: LensType.row,
                      color: LensColor.gray10,
                    ),
                  ),
                ),
                const Icon(
                  Icons.edit_outlined,
                  size: LensSize.iconSmall,
                  color: LensColor.accent,
                ),
              ],
            ),
          ),
        ),
        const _SheetSection('SAVE AS'),
        _CheckRow(
          icon: Icons.image_outlined,
          label: 'Image',
          hint: 'One JPEG per page, in the gallery',
          checked: _image,
          onChanged: (value) {
            setState(() => _image = value);
            widget.onImage(value);
          },
        ),
        _CheckRow(
          icon: Icons.picture_as_pdf_outlined,
          label: 'PDF',
          hint: 'All pages in one document',
          checked: _pdf,
          onChanged: (value) {
            setState(() => _pdf = value);
            widget.onPdf(value);
          },
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.checked,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String hint;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      checked: checked,
      label: label,
      child: InkWell(
        onTap: () => onChanged(!checked),
        child: Padding(
          padding: const EdgeInsets.all(LensSpace.md),
          child: Row(
            children: [
              Icon(icon, size: LensSize.icon, color: LensColor.gray10),
              const SizedBox(width: LensSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: LensType.row,
                        color: LensColor.gray10,
                      ),
                    ),
                    Text(
                      hint,
                      style: const TextStyle(
                        fontSize: LensType.label,
                        color: LensColor.gray8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LensSpace.md),
              // `lensCheckableGroup`: accent fill + white tick when on, accent
              // outline when off.
              Container(
                width: LensSize.iconSmall,
                height: LensSize.iconSmall,
                decoration: BoxDecoration(
                  color: checked ? LensColor.accent : null,
                  border: Border.all(color: LensColor.accent, width: 2),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: checked
                    ? const Icon(Icons.check, size: 14, color: LensColor.gray0)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tone presets for the current page. Tapping one bakes the tone preview shown
/// on the pager; nothing is re-encoded until the session is saved.
class _FilterSheet extends StatelessWidget {
  const _FilterSheet({required this.scrollController, required this.selected});

  final ScrollController scrollController;
  final ScanFilter selected;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: EdgeInsets.zero,
      children: [
        const _SheetHandle(),
        const Padding(
          padding: EdgeInsets.fromLTRB(LensSpace.md, LensSpace.xs, LensSpace.md, LensSpace.md),
          child: Text(
            'Filters',
            style: TextStyle(
              fontSize: LensType.sheet,
              fontWeight: FontWeight.w500,
              color: LensColor.gray10,
            ),
          ),
        ),
        for (final filter in ScanFilter.values)
          InkWell(
            onTap: () => Navigator.pop(context, filter),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LensSpace.md,
                vertical: LensSpace.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      filter.label,
                      style: const TextStyle(
                        fontSize: LensType.row,
                        color: LensColor.gray10,
                      ),
                    ),
                  ),
                  if (filter == selected)
                    const Icon(Icons.check, size: LensSize.icon, color: LensColor.accent),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Drag the pages into a new order.
class _ReorderSheet extends StatefulWidget {
  const _ReorderSheet({required this.scrollController, required this.pages});

  final ScrollController scrollController;
  final List<_Page> pages;

  @override
  State<_ReorderSheet> createState() => _ReorderSheetState();
}

class _ReorderSheetState extends State<_ReorderSheet> {
  late final List<_Page> _order = widget.pages;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.zero,
      children: [
        const _SheetHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LensSpace.md,
            LensSpace.xs,
            LensSpace.md,
            LensSpace.md,
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Reorder',
                  style: TextStyle(
                    fontSize: LensType.sheet,
                    fontWeight: FontWeight.w500,
                    color: LensColor.gray10,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, List<_Page>.of(_order)),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: LensSize.filmThumbHeight + LensSpace.md,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(horizontal: LensSpace.md),
            itemCount: _order.length,
            onReorderItem: (from, to) => setState(() {
              final page = _order.removeAt(from);
              _order.insert(to, page);
            }),
            itemBuilder: (context, index) {
              final page = _order[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey<_Page>(page),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(right: LensSpace.sm),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(colorMatrixFor(page.filter)),
                    child: RotatedBox(
                      quarterTurns: page.turns,
                      child: Image.memory(
                        page.bytes,
                        width: page.turns.isOdd
                            ? LensSize.filmThumbHeight
                            : LensSize.filmThumbWidth,
                        height: page.turns.isOdd
                            ? LensSize.filmThumbWidth
                            : LensSize.filmThumbHeight,
                        fit: BoxFit.cover,
                        cacheWidth: 160,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
