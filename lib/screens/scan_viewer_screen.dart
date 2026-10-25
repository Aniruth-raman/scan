import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../models/scan_entry.dart';

/// Opens a saved scan: images zoom in-app, PDFs open in the system
/// preview/print flow.
class ScanViewerScreen extends StatelessWidget {
  const ScanViewerScreen({super.key, required this.entry});

  final ScanEntry entry;

  Future<void> _previewPdf(BuildContext context) async {
    try {
      final bytes = await File(entry.filePath).readAsBytes();
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: entry.title,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open PDF: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(entry.title)),
      body: entry.isPdf
          ? Center(
              child: FilledButton.icon(
                onPressed: () => _previewPdf(context),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Preview / print PDF'),
              ),
            )
          : Center(
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.file(
                  File(entry.filePath),
                  fit: BoxFit.contain,
                ),
              ),
            ),
    );
  }
}