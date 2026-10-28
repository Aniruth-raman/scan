import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../data/scan_repository.dart';
import '../design/scan_tokens.dart';
import '../design/scan_top_bar.dart';
import '../models/scan_entry.dart';
import '../services/document_scan_session.dart';
import '../services/native_image_kit.dart';
import '../services/scan_exporter.dart';
import 'review_screen.dart';
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

class _HistoryScreenState extends State<HistoryScreen>
    with WidgetsBindingObserver {
  late Future<_ScanList> _scans;

  /// Files the user dismissed from this screen. Deliberately in memory: the
  /// original forgets the dismissal as soon as you come back, and the file was
  /// never ours to delete.
  final Set<String> _dismissed = <String>{};

  @override
  void initState() {
    super.initState();
    _scans = _load();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Files can land in the shared folders while the app is in the background,
    // and a dismissal is only meant to last while you are looking at the list.
    if (state == AppLifecycleState.resumed) {
      _dismissed.clear();
      _refresh();
    }
  }

  void _refresh() {
    final scans = _load();
    setState(() {
      _scans = scans;
    });
  }

  /// Re-reads the folders, asking for gallery access on an explicit pull (the
  /// one moment the user is clearly asking to see what is out there). A pull
  /// also forgets past dismissals: "show me everything".
  Future<void> _refreshWithAccess() async {
    _dismissed.clear();
    final scans = _load(requestAccess: true);
    setState(() {
      _scans = scans;
    });
    await scans;
  }

  /// The records this app owns plus everything sitting in the shared folders.
  ///
  /// A file is listed once: the app's own exports are recognised by the content
  /// URI it kept (and, for rows saved before that was recorded, by file name),
  /// and anything the user removed from the list is filtered by URI.
  Future<_ScanList> _load({bool requestAccess = false}) async {
    final records = await widget.repository.all();
    if (!NativeImageKit.isSupported) {
      return _ScanList(records: records, imported: const <SharedMedia>[]);
    }

    var media = const <SharedMedia>[];
    try {
      // A wedged permission request or MediaStore query must not hold the scan
      // list hostage; records alone are always shown.
      media = await _indexShared(requestAccess: requestAccess)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // An indexer failure must not take the scan list with it.
    }

    final owned = <String>{
      for (final record in records)
        if (record.sharedUri != null) record.sharedUri!,
    };
    // Legacy rows predate `sharedUri`; their album copy has the same name, but
    // MediaStore rewrites `:` to `_` and appends ` (1)` on a clash, so compare a
    // loose key rather than the raw title.
    final ownedNames = <String>{
      for (final record in records) _nameKey(ScanExporter.fileStem(record.title)),
    };
    final imported = media.where((file) {
      if (_dismissed.contains(file.uri) || owned.contains(file.uri)) {
        return false;
      }
      final suffix = RegExp(r'\s*\(\d+\)$');
      return !ownedNames.contains(_nameKey(file.title)) &&
          !ownedNames.contains(_nameKey(file.title.replaceFirst(suffix, '')));
    }).toList();

    return _ScanList(records: records, imported: imported);
  }

  /// File names are compared with punctuation and case removed: the album copy of
  /// `Scan 24 Oct, 10:32` comes back from MediaStore as `Scan 24 Oct, 10_32`.
  static String _nameKey(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Reads both shared folders once gallery access is granted.
  Future<List<SharedMedia>> _indexShared({required bool requestAccess}) async {
    if (!await _mediaAccess(requestAccess: requestAccess)) {
      return const <SharedMedia>[];
    }
    return NativeImageKit.listShared();
  }

  /// Reading media the app did not write needs a gallery grant (READ_MEDIA_IMAGES
  /// from Android 13, storage before that). Without it the indexer would only
  /// ever see this app's own exports, so the list stays records-only.
  Future<bool> _mediaAccess({required bool requestAccess}) async {
    try {
      for (final permission in const <Permission>[
        Permission.photos,
        Permission.storage,
      ]) {
        final status = await permission.status;
        if (status.isGranted) return true;
        if (!requestAccess || status.isPermanentlyDenied) continue;
        if ((await permission.request()).isGranted) return true;
      }
    } catch (_) {
      // No permission plugin (or a wedged request): show records only.
    }
    return false;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _capture() async {
    // Google's scanner owns the whole capture flow - viewfinder, edge
    // detection, crop, filters - and runs under Play services' camera
    // permission, so this app asks for nothing and ships no model.
    final List<Uint8List> pages;
    try {
      pages = await DocumentScanSession.run();
    } on PlatformException catch (error) {
      if (!mounted) return;
      _snack('Scanner could not start: ${error.message ?? error.code}');
      return;
    }
    if (!mounted || pages.isEmpty) return;
    final result = await Navigator.push<ReviewResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(pages: pages, exporter: widget.exporter),
      ),
    );
    if (!mounted) return;
    // Coming back to the list is a fresh look: dismissals do not survive it.
    _dismissed.clear();
    _refresh();
    if (result != null) {
      _snack(result.message);
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
                leading: Icon(item.$3, color: ScanColor.gray9),
                title: Text(
                  item.$2,
                  style: const TextStyle(color: ScanColor.gray10),
                ),
                onTap: () => Navigator.pop(sheetContext, item.$1),
              ),
            _LocationFooter(path: _locationFor(isPdf: entry.isPdf)),
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

  /// Opens a file that lives in a shared collection, by its content URI.
  Future<void> _openImported(SharedMedia media) async {
    try {
      await NativeImageKit.openFile(path: media.uri, mimeType: media.mime);
    } catch (error) {
      _snack('Could not open ${media.name}: $error');
    }
  }

  /// A file this app did not create gets a shorter menu: it can be opened or
  /// dropped from the list, but it is not ours to rename or delete.
  Future<void> _menuImported(SharedMedia media) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new, color: ScanColor.gray9),
              title: const Text(
                'Open',
                style: TextStyle(color: ScanColor.gray10),
              ),
              onTap: () => Navigator.pop(sheetContext, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: ScanColor.gray9),
              title: const Text(
                'Remove from My Scans',
                style: TextStyle(color: ScanColor.gray10),
              ),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
            _LocationFooter(path: _locationFor(isPdf: media.isPdf)),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        await _openImported(media);
      case 'remove':
        // The file stays on disk; the dismissal lasts for this screen only, the
        // way the original forgets it as soon as you navigate away.
        setState(() => _dismissed.add(media.uri));
        _refresh();
        _snack('Removed “${media.title}” from My Scans');
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
        backgroundColor: ScanColor.gray1,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Column(
                children: [
                  const ScanListTopBar(title: 'My Scans'),
                  Expanded(
                    child: FutureBuilder<_ScanList>(
                      future: _scans,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: ScanColor.accent,
                              ),
                            ),
                          );
                        }
                        final list = snapshot.data ?? const _ScanList.empty();
                        if (list.isEmpty) {
                          return _EmptyScans(bottomInset: bottomInset);
                        }
                        return _ScanGrid(
                          items: list.items,
                          bottomInset: bottomInset,
                          onOpen: _open,
                          onMenu: _menu,
                          onOpenImported: _openImported,
                          onMenuImported: _menuImported,
                          onRefresh: _refreshWithAccess,
                        );
                      },
                    ),
                  ),
                ],
              ),
              Positioned(
                right: ScanSpace.md,
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

/// Where a file lives, in the same words the original uses for its own folder.
String _locationFor({required bool isPdf}) => isPdf
    ? 'Phone Storage > Download > ${ScanExporter.pdfFolder}'
    : 'Phone Storage > Pictures > ${ScanExporter.imageFolder}';

/// The records this app owns, merged with everything the folder indexer found.
class _ScanList {
  const _ScanList({required this.records, required this.imported});

  const _ScanList.empty()
    : records = const <ScanEntry>[],
      imported = const <SharedMedia>[];

  final List<ScanEntry> records;
  final List<SharedMedia> imported;

  bool get isEmpty => records.isEmpty && imported.isEmpty;

  /// One list, newest first, whichever side it came from.
  List<_FlowItem> get items {
    final items = <_FlowItem>[
      for (final record in records) _OwnedItem(record),
      for (final media in imported) _ImportedItem(media),
    ];
    items.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return items;
  }
}

/// A tile in the scan grid: either one of our records or an indexed file.
sealed class _FlowItem {
  DateTime get sortKey;
}

class _OwnedItem implements _FlowItem {
  const _OwnedItem(this.entry);

  final ScanEntry entry;

  @override
  DateTime get sortKey => entry.createdAt;
}

class _ImportedItem implements _FlowItem {
  const _ImportedItem(this.media);

  final SharedMedia media;

  @override
  DateTime get sortKey => media.modified;
}

/// `fragment_recent_items_info_parent`: the 46 dp band under the scan menu that
/// says where the file went.
///
/// The location band names the shared copy the user can actually reach - the
/// gallery album for an image, the Downloads folder for a PDF - because the
/// record itself lives in app storage, which no file manager shows.
class _LocationFooter extends StatelessWidget {
  const _LocationFooter({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Location of the file: $path',
      excludeSemantics: true,
      child: Container(
        height: ScanSize.locationBandHeight,
        color: ScanColor.locationBand,
        padding: const EdgeInsets.symmetric(horizontal: ScanSpace.md),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline,
              size: ScanSize.icon,
              color: ScanColor.locationCaption,
            ),
            const SizedBox(width: ScanSpace.md),
            Expanded(
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: ScanType.body,
                  color: ScanColor.locationCaption,
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
class _EmptyScans extends StatelessWidget {
  const _EmptyScans({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          ScanSpace.lg,
          0,
          ScanSpace.lg,
          bottomInset,
        ),
        child: const Text(
          'No scans yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: ScanType.body,
            color: ScanColor.gray8,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _ScanGrid extends StatelessWidget {
  const _ScanGrid({
    required this.items,
    required this.bottomInset,
    required this.onOpen,
    required this.onMenu,
    required this.onOpenImported,
    required this.onMenuImported,
    required this.onRefresh,
  });

  final List<_FlowItem> items;
  final double bottomInset;
  final ValueChanged<ScanEntry> onOpen;
  final ValueChanged<ScanEntry> onMenu;
  final ValueChanged<SharedMedia> onOpenImported;
  final ValueChanged<SharedMedia> onMenuImported;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: ScanColor.accent,
      onRefresh: onRefresh,
      child: GridView.builder(
        // Reachable even when the grid is short, so the pull works.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          ScanSpace.sm,
          ScanSpace.md,
          ScanSpace.sm,
          88 + bottomInset,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: ScanSpace.xs,
          mainAxisSpacing: ScanSpace.md,
          childAspectRatio: 1,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return switch (item) {
            _OwnedItem(:final entry) => _ScanTile(
              title: entry.title,
              isPdf: entry.isPdf,
              thumbPath: entry.thumbPath,
              filePath: entry.filePath,
              semanticLabel:
                  '${entry.title}, ${entry.isPdf ? 'PDF' : 'image'}, '
                  'saved ${DateFormat.yMMMd().add_jm().format(entry.createdAt)}',
              onOpen: () => onOpen(entry),
              onMenu: () => onMenu(entry),
            ),
            _ImportedItem(:final media) => _ScanTile(
              title: media.title,
              isPdf: media.isPdf,
              thumbBytes: media.thumb,
              semanticLabel:
                  '${media.title}, ${media.isPdf ? 'PDF' : 'image'}, '
                  'found in ${media.isPdf ? 'Downloads' : 'Pictures'}',
              onOpen: () => onOpenImported(media),
              onMenu: () => onMenuImported(media),
            ),
          };
        },
      ),
    );
  }
}

/// A 176 dp square tile: page on white, fading into the title row.
///
/// The same tile renders an owned record and a file the indexer found, so the
/// grid cannot show two different weights for the same shape.
class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.title,
    required this.isPdf,
    required this.semanticLabel,
    required this.onOpen,
    required this.onMenu,
    this.thumbPath,
    this.thumbBytes,
    this.filePath,
  });

  final String title;
  final bool isPdf;
  final String semanticLabel;
  final VoidCallback onOpen;
  final VoidCallback onMenu;
  final String? thumbPath;
  final Uint8List? thumbBytes;
  final String? filePath;

  static const double _radius = ScanRadius.card;
  static const double _footerHeight = 32;

  Widget _fallback() => Center(
    child: Icon(
      isPdf ? Icons.picture_as_pdf_outlined : Icons.broken_image_outlined,
      size: ScanSize.icon,
      color: ScanColor.gray6,
    ),
  );

  Widget _preview() {
    final bytes = thumbBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => _fallback(),
      );
    }
    final thumb = thumbPath;
    final path = (thumb != null && File(thumb).existsSync()) ? thumb : filePath;
    if (path == null) return _fallback();
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => _fallback(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
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
            color: ScanColor.gray0,
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
                            ScanColor.gray0.withValues(alpha: 0),
                            ScanColor.gray0,
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
                      const SizedBox(width: ScanSpace.xxs),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: ScanType.label,
                            color: ScanColor.gray7,
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
                            color: ScanColor.gray9,
                          ),
                        ),
                      ),
                      const SizedBox(width: ScanSpace.xxs),
                    ],
                  ),
                ),
                if (isPdf)
                  Positioned(
                    top: ScanSpace.xxs,
                    right: ScanSpace.xxs,
                    child: IgnorePointer(
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                          color: ScanColor.gray0,
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
                          color: ScanColor.accent,
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
        width: ScanSize.scanFab,
        height: ScanSize.scanFab,
        child: Material(
          color: ScanColor.accent,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: const Color(0x40000000),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const Center(
              child: Icon(
                Icons.photo_camera,
                size: ScanSize.icon,
                color: ScanColor.gray0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
