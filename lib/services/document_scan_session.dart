import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

/// Runs Google's ML Kit document scanner and returns the pages it produced.
///
/// The viewfinder, edge detection, crop, rotation and the shadow/contrast
/// filters all live in Google Play services, which downloads the scanner module
/// on first use. So this app needs no bundled model, no camera permission and no
/// per-frame code: it opens the scanner and gets finished JPEG pages back.
///
/// Pages arrive as paths into this app's cache directory; they are read into
/// memory because the rest of the app works from bytes.
class DocumentScanSession {
  DocumentScanSession._();

  /// ML Kit's own ceiling for one session. A scan is a document, not an archive.
  static const int _pageLimit = 20;

  static final DocumentScannerOptions _options = DocumentScannerOptions(
    documentFormats: const {DocumentFormat.jpeg},
    mode: ScannerMode.full,
    pageLimit: _pageLimit,
  );

  /// Opens the scanner and returns the page JPEGs in order.
  ///
  /// Returns an empty list when the user backs out of the scanner without
  /// keeping a page. Throws when the scanner cannot start at all - usually
  /// Google Play services missing, disabled or out of date.
  static Future<List<Uint8List>> run() async {
    final scanner = DocumentScanner(options: _options);
    try {
      final result = await scanner.scanDocument();
      final paths = result.images ?? const <String>[];
      final pages = <Uint8List>[];
      for (final path in paths) {
        pages.add(await File(path).readAsBytes());
      }
      return pages;
    } finally {
      await scanner.close();
    }
  }
}
