import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../data/scan_repository.dart';
import '../design/lens_tokens.dart';
import '../design/lens_top_bar.dart';
import '../models/scan_entry.dart';
import '../services/native_image_kit.dart';
import '../services/scan_exporter.dart';
import 'camera_screen.dart';
import 'scan_viewer_screen.dart';

/// "My Scans" — the home list.
///
/// Geometry is taken from the original: a 71.5 dp flat bar, then a two-column
/// grid of 176 dp square tiles inset 12 dp with an 8 dp gutter and a 16 dp
/// vertical gap. Each tile fades to white over its bottom 48 dp so the 32 dp
/// title row always reads, whatever the page behind it looks like.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.repository,
    required this.exporter,
  });

  final ScanRepository repository;
  final ScanExporter exporter;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<ScanEntry>> _scans;

  @override
  void initState() {
    super.initState();
    _scans = widget.repository.all();
  }

  void _refresh() {
    final scans = widget.repository.all();
    setState(() {
      _scans = scans;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _capture() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _snack('Camera permission is required to capture.');
      return;
    }
    if (!mounted) return;
    // The capture stage owns the whole session: shoot, crop, add pages, and
    // hand pages to review. It reports back only when something was saved.
    final message = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => CameraScreen(exporter: widget.exporter),
      ),
    );
    if (!mounted) return;
    _refresh();
    if (message != null) {
      _snack(message);
    }
  }

  Future<void> _open(ScanEntry entry) async {
    if (entry.isPdf) {
      try {
        await NativeImageKit.openFile(
          path: entry.filePath,
          mimeType: 'application/pdf',
        );
      } catch (error) {
        _snack('Could not open PDF: $error');
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ScanViewerScreen(entry: entry)),
    );
  }

  Future<void> _share(ScanEntry entry) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(entry.filePath)], title: entry.title),
    );
  }

  Future<void> _rename(ScanEntry entry) async {
    var value = entry.title;
    final name = await showDialog<String>(
      context: context,
      // A TextFormField owns its own editing state, so nothing is disposed
      // while the dialog's exit animation is still rebuilding.
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename scan'),
        content: TextFormField(
          initialValue: entry.title,
          autofocus: true,
          onChanged: (text) => value = text,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, value.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || entry.id == null) return;
    await widget.repository.rename(entry.id!, name);
    if (mounted) _refresh();
  }

  Future<void> _delete(ScanEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.exporter.delete(entry);
    if (mounted) _refresh();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted “${entry.title}”'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _menu(ScanEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        // Scrollable so a short sheet box clamps instead of overflowing.
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in const <(String, String, IconData)>[
              ('open', 'Open', Icons.open_in_new),
              ('share', 'Share', Icons.share_outlined),
              ('rename', 'Rename', Icons.edit_outlined),
              ('delete', 'Delete', Icons.delete_outline),
            ])
              ListTile(
                leading: Icon(item.$3, color: LensColor.gray9),
                title: Text(
                  item.$2,
                  style: const TextStyle(color: LensColor.gray10),
                ),
                onTap: () => Navigator.pop(sheetContext, item.$1),
              ),
            _LocationFooter(entry: entry),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        await _open(entry);
      case 'share':
        await _share(entry);
      case 'rename':
        await _rename(entry);
      case 'delete':
        await _delete(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Edge-to-edge is mandatory from Android 15, so the surface has to paint
    // behind both system bars; only the top inset is honoured structurally.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The bar is #FAFAFA, so the system glyphs must be dark. (The original
      // paints the status bar black, but that attribute is ignored on modern
      // Android and white glyphs would vanish against this surface.)
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: LensColor.gray1,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Column(
                children: [
                  const LensListTopBar(title: 'My Scans'),
                  Expanded(
                    child: FutureBuilder<List<ScanEntry>>(
                      future: _scans,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: LensColor.accent,
                              ),
                            ),
                          );
                        }
                        final scans = snapshot.data ?? const <ScanEntry>[];
                        if (scans.isEmpty) {
                          return _EmptyScans(bottomInset: bottomInset);
                        }
                        return _ScanGrid(
                          scans: scans,
                          bottomInset: bottomInset,
                          onOpen: _open,
                          onMenu: _menu,
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                right: LensSpace.md,
                bottom: 40 + bottomInset,
                child: _CaptureButton(onPressed: _capture),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `fragment_recent_items_info_parent`: the 46 dp band under the scan menu that
/// says where the file went.
///
/// The original shows its own folder here ("Phone Storage > Pictures > Office
/// Lens"). `lens_lite` keeps its record private, so the band names the shared
/// copy the user can actually reach: the gallery album for an image, the
/// Downloads folder for a PDF.
class _LocationFooter extends StatelessWidget {
  const _LocationFooter({required this.entry});

  final ScanEntry entry;

  String get _path => entry.isPdf
      ? 'Phone Storage > Download > Lens Lite'
      : 'Phone Storage > Pictures > Lens Lite';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Location of the file: $_path',
      excludeSemantics: true,
      child: Container(
        height: LensSize.locationBandHeight,
        color: LensColor.locationBand,
        padding: const EdgeInsets.symmetric(horizontal: LensSpace.md),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline,
              size: LensSize.icon,
              color: LensColor.locationCaption,
            ),
            const SizedBox(width: LensSpace.md),
            Expanded(
              child: Text(
                _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: LensType.body,
                  color: LensColor.locationCaption,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of centred secondary text, as in the original.
class _EmptyScans extends StatelessWidget {  const _EmptyScans({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          LensSpace.lg,
          0,
          LensSpace.lg,
          bottomInset,
        ),
        child: const Text(
          'No scans yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: LensType.body,
            color: LensColor.gray8,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _ScanGrid extends StatelessWidget {
  const _ScanGrid({
    required this.scans,
    required this.bottomInset,
    required this.onOpen,
    required this.onMenu,
  });

  final List<ScanEntry> scans;
  final double bottomInset;
  final ValueChanged<ScanEntry> onOpen;
  final ValueChanged<ScanEntry> onMenu;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        LensSpace.sm,
        LensSpace.md,
        LensSpace.sm,
        88 + bottomInset,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: LensSpace.xs,
        mainAxisSpacing: LensSpace.md,
        childAspectRatio: 1,
      ),
      itemCount: scans.length,
      itemBuilder: (context, index) {
        final entry = scans[index];
        return _ScanTile(
          entry: entry,
          onOpen: () => onOpen(entry),
          onMenu: () => onMenu(entry),
        );
      },
    );
  }
}

/// A 176 dp square tile: page on white, fading into the title row.
class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.entry,
    required this.onOpen,
    required this.onMenu,
  });

  final ScanEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  static const double _radius = LensRadius.card;
  static const double _footerHeight = 32;

  String get _semanticLabel {
    final kind = entry.isPdf ? 'PDF' : 'image';
    final date = DateFormat.yMMMd().add_jm().format(entry.createdAt);
    return '${entry.title}, $kind, saved $date';
  }

  Widget _preview() {
    final thumb = entry.thumbPath;
    final path = (thumb != null && File(thumb).existsSync())
        ? thumb
        : entry.filePath;
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => Center(
        child: Icon(
          entry.isPdf ? Icons.picture_as_pdf_outlined : Icons.broken_image_outlined,
          size: LensSize.icon,
          color: LensColor.gray6,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _semanticLabel,
      onTap: onOpen,
      onLongPress: onMenu,
      excludeSemantics: true,
      child: GestureDetector(
        onLongPress: onMenu,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Material(
            color: LensColor.gray0,
            borderRadius: BorderRadius.circular(_radius),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                InkWell(onTap: onOpen, child: _preview()),
                // The original fades the page into white so the title is
                // legible over any content.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 48,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            LensColor.gray0.withValues(alpha: 0),
                            LensColor.gray0,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: _footerHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: LensSpace.xxs),
                      Expanded(
                        child: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: LensType.label,
                            color: LensColor.gray7,
                            height: 1.2,
                          ),
                        ),
                      ),
                      // InkResponse keeps the 4 dp visual inset while still
                      // giving a comfortable target.
                      SizedBox(
                        width: 32,
                        height: _footerHeight,
                        child: InkResponse(
                          onTap: onMenu,
                          radius: 20,
                          child: const Icon(
                            Icons.more_vert,
                            size: 20,
                            color: LensColor.gray9,
                          ),
                        ),
                      ),
                      const SizedBox(width: LensSpace.xxs),
                    ],
                  ),
                ),
                if (entry.isPdf)
                  Positioned(
                    top: LensSpace.xxs,
                    right: LensSpace.xxs,
                    child: IgnorePointer(
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                          color: LensColor.gray0,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x1F000000),
                              blurRadius: 3,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.picture_as_pdf,
                          size: 14,
                          color: LensColor.accent,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 48 dp accent circle, 16 dp from the end and 40 dp from the bottom.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New capture',
      child: SizedBox(
        width: LensSize.scanFab,
        height: LensSize.scanFab,
        child: Material(
          color: LensColor.accent,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: const Color(0x40000000),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const Center(
              child: Icon(
                Icons.photo_camera,
                size: LensSize.icon,
                color: LensColor.gray0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
