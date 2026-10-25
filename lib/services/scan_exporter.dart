import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../data/scan_repository.dart';
import '../models/scan_entry.dart';
import 'native_image_kit.dart';

/// Turns captured pages into a saved image or a PDF and records the result in
/// scan history — capture → export (image | PDF) → tracked in "My Scans".
///
/// Encoding, thumbnailing and PDF assembly are delegated to the Android side.
/// The Dart layer only moves bytes and bookkeeping, so a page is re-encoded
/// exactly once between the camera and the saved file.
class ScanExporter {
  ScanExporter({required this.repository, required this.storageDirectory});

  final ScanRepository repository;
  final Directory storageDirectory;

  /// Default file name, matching the original's date-based naming.
  static String defaultTitle(DateTime when) =>
      'Scan ${DateFormat.yMMMd().add_jm().format(when)}';

  /// Saves one or more pages as a JPEG in app storage and tracks it.
  ///
  /// Multi-page image saves keep the first page as the record; use PDF for the
  /// full set.
  Future<ScanEntry> saveImage(
    Uint8List pageBytes, {
    String? title,
    ScanFilter filter = ScanFilter.none,
  }) async {
    final now = DateTime.now();
    final path = p.join(
      storageDirectory.path,
      'scan_${now.microsecondsSinceEpoch}.jpg',
    );
    await File(path).writeAsBytes(pageBytes, flush: true);
    final thumbPath = await _writeThumbnail(pageBytes, now);
    final entry = ScanEntry(
      title: title ?? defaultTitle(now),
      kind: 'image',
      filePath: path,
      thumbPath: thumbPath,
      createdAt: now,
    );
    return repository.insert(entry);
  }

  /// Single-page convenience wrapper around [exportPdfPages].
  Future<ScanEntry> exportPdf(Uint8List imageBytes, {String? title}) =>
      exportPdfPages(<Uint8List>[imageBytes], title: title);

  /// Writes a full-bleed, multi-page PDF in app storage and tracks it.
  ///
  /// Pages are emitted by [PdfDocument] on the Android side at each page's own
  /// aspect ratio, so a scan fills the sheet instead of being letter-boxed
  /// inside margins.
  Future<ScanEntry> exportPdfPages(
    List<Uint8List> pages, {
    String? title,
  }) async {
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final now = DateTime.now();
    final effectiveTitle = title ?? defaultTitle(now);
    final path = p.join(
      storageDirectory.path,
      'scan_${now.microsecondsSinceEpoch}.pdf',
    );

    await NativeImageKit.writePdf(pages: pages, path: path);

    final thumbPath = await _writeThumbnail(pages.first, now);
    final entry = ScanEntry(
      title: effectiveTitle,
      kind: 'pdf',
      filePath: path,
      thumbPath: thumbPath,
      createdAt: now,
    );
    return repository.insert(entry);
  }

  /// Removes a scan from history and deletes its files from disk.
  Future<void> delete(ScanEntry entry) async {
    if (entry.id != null) await repository.delete(entry.id!);
    final files = <File>[File(entry.filePath)];
    final thumb = entry.thumbPath;
    if (thumb != null) files.add(File(thumb));
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<String?> _writeThumbnail(Uint8List bytes, DateTime stamp) async {
    try {
      final encoded = await NativeImageKit.thumbnail(bytes, maxEdge: 320);
      final path = p.join(
        storageDirectory.path,
        'thumb_${stamp.microsecondsSinceEpoch}.jpg',
      );
      await File(path).writeAsBytes(encoded, flush: true);
      return path;
    } catch (_) {
      // A missing thumbnail degrades the list row; it must not fail the save.
      return null;
    }
  }
}
