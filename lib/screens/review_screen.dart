import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../services/scan_exporter.dart';

/// Review screen: the captured (already cropped) frame with the two exports
/// this app supports — save to the device Gallery and export as PDF — plus
/// sharing the saved file. No cloud or office-suite integrations.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.imageBytes,
    required this.exporter,
  });

  final Uint8List imageBytes;
  final ScanExporter exporter;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController _titleController;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: ScanExporter.defaultTitle(DateTime.now()));
  }

  @override
  void dispose() {
    _titleController.dispose();
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
      final entry =
          await widget.exporter.saveImage(widget.imageBytes, title: _title);
      String? galleryProblem;
      try {
        await Gal.putImage(entry.filePath, album: 'Lens Lite');
      } on GalException catch (exception) {
        galleryProblem = exception.type.name;
      } on Exception catch (exception) {
        galleryProblem = '$exception';
      }
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(
        context,
        galleryProblem == null
            ? 'Saved to Gallery: ${entry.title}'
            : 'Saved in My Scans — gallery unavailable ($galleryProblem)',
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
      final entry =
          await widget.exporter.exportPdf(widget.imageBytes, title: _title);
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
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: InteractiveViewer(
                  maxScale: 6,
                  child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
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
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _saveToGallery,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Save to gallery'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _exportPdf,
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('Export PDF'),
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