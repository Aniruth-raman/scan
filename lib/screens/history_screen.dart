import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../data/scan_repository.dart';
import '../models/scan_entry.dart';
import '../services/scan_exporter.dart';
import 'camera_screen.dart';
import 'review_screen.dart';
import 'scan_viewer_screen.dart';

/// "My Scans" home: a Material 3 large-top-bar history of captured files
/// with the capture entry point, mirroring the original's recent-files flow.
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
    final bytes = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(builder: (_) => const CameraScreen()),
    );
    if (bytes == null || !mounted) return;
    final message = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReviewScreen(imageBytes: bytes, exporter: widget.exporter),
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
        final bytes = await File(entry.filePath).readAsBytes();
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: entry.title,
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
    final controller = TextEditingController(text: entry.title);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename scan'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
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

  Widget _thumbnail(ScanEntry entry) {
    final thumb = entry.thumbPath;
    if (thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(thumb),
          width: 52,
          height: 52,
          fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        entry.isPdf ? Icons.picture_as_pdf : Icons.image,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.document_scanner_outlined,
              size: 44,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'No scans yet',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap Capture to scan your first document.\n'
            'Edges are detected automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _scanCard(BuildContext context, ScanEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(entry),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              _thumbnail(entry),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${entry.isPdf ? 'PDF' : 'Image'} · '
                      '${DateFormat.yMMMd().add_jm().format(entry.createdAt)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'open':
                      _open(entry);
                    case 'share':
                      _share(entry);
                    case 'rename':
                      _rename(entry);
                    case 'delete':
                      _delete(entry);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'open', child: Text('Open')),
                  PopupMenuItem(value: 'share', child: Text('Share')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _capture,
        icon: const Icon(Icons.camera_alt),
        label: const Text('Capture'),
      ),
      body: FutureBuilder<List<ScanEntry>>(
        future: _scans,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const CustomScrollView(
              slivers: [
                SliverAppBar.large(title: Text('My Scans')),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            );
          }
          final scans = snapshot.data ?? const <ScanEntry>[];
          return CustomScrollView(
            slivers: [
              const SliverAppBar.large(
                pinned: true,
                title: Text('My Scans'),
              ),
              if (scans.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _emptyState(context),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) =>
                          _scanCard(context, scans[index]),
                      childCount: scans.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}