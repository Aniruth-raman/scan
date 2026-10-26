import 'dart:io';

import 'package:flutter/material.dart';

import '../design/scan_top_bar.dart';
import '../design/scan_tokens.dart';
import '../models/scan_entry.dart';

/// Opens a saved image full-screen. PDFs are handed to the system viewer from
/// the scan list instead, so this screen never sees one.
class ScanViewerScreen extends StatelessWidget {
  const ScanViewerScreen({super.key, required this.entry});

  final ScanEntry entry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScanColor.stageBlack,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ScanListTopBar(
              title: entry.title,
              titleColor: ScanColor.gray0,
              leading: ScanBarAction(
                icon: Icons.arrow_back,
                semanticLabel: 'Back',
                color: ScanColor.gray0,
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: InteractiveViewer(
                maxScale: 6,
                child: Center(
                  child: Image.file(
                    File(entry.filePath),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
