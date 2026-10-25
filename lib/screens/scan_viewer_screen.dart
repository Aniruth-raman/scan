import 'dart:io';

import 'package:flutter/material.dart';

import '../models/scan_entry.dart';
import '../services/native_image_kit.dart';

/// Opens a saved scan: images zoom in-app, PDFs open in the system viewer.
class ScanViewerScreen extends StatelessWidget {
  const ScanViewerScreen({super.key, required this.entry});

  final ScanEntry entry;

  Future<void> _openPdf(BuildContext context) async {
    try {
      await NativeImageKit.openFile(
        path: entry.filePath,
        mimeType: 'application/pdf',
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
                onPressed: () => _openPdf(context),
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Open PDF'),
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
