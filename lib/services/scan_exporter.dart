import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../data/scan_repository.dart';
import '../models/scan_entry.dart';
import 'native_image_kit.dart';

/// Turns captured pages into a saved image or a PDF.
///
/// The image is the record: it is written to app storage under the scan's own
/// name and tracked in "My Scans". A PDF is an export, not a record — it goes
/// straight to shared Downloads and is deliberately left out of the history, the
/// way the original keeps the JPEG and nothing else.
///
/// Encoding, thumbnailing and PDF assembly are delegated to the Android side.
/// The Dart layer only moves bytes and bookkeeping, so a page is re-encoded
/// exactly once between the camera and the saved file.
class ScanExporter {
  ScanExporter({required this.repository, required this.storageDirectory});

  final ScanRepository repository;
  final Directory storageDirectory;

  /// `Download/<folder>` on the platform side, shared so any file manager can
  /// reach the exported document.
  static const pdfFolder = 'Lens Lite';

  /// Default file name, matching the original's date-based naming.
  static String defaultTitle(DateTime when) =>
      'Scan ${DateFormat.yMMMd().add_jm().format(when)}';

  /// Turns a title into a file stem: no path separators, no characters the
  /// file browsers reject, no leading or trailing dots, and short enough for
  /// any filesystem.
  ///
  /// `:` and `,` survive on purpose — the default title is
  /// "Scan 24 Oct 2026, 10:32" and stripping them would mangle every name.
  static String fileStem(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '')
        .trim();
    if (cleaned.isEmpty) return 'Scan';
    return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80).trim();
  }

  /// Saves one page as a JPEG in app storage, named after [title], and tracks
  /// it in the history.
  ///
  /// Multi-page sessions save one file per page; the title gets `(1 of N)`
  /// appended by the caller so the files stay distinguishable.
  Future<ScanEntry> saveImage(
    Uint8List pageBytes, {
    String? title,
    ScanFilter filter = ScanFilter.none,
  }) async {
    final now = DateTime.now();
    final effectiveTitle = title ?? defaultTitle(now);
    final file = _freeFile(effectiveTitle, '.jpg');
    await file.writeAsBytes(pageBytes, flush: true);
    final thumbPath = await _writeThumbnail(pageBytes, now);
    final entry = ScanEntry(
      title: effectiveTitle,
      kind: 'image',
      filePath: file.path,
      thumbPath: thumbPath,
      createdAt: now,
    );
    return repository.insert(entry);
  }

  /// Writes one PDF for [pages] into shared Downloads, named after [title], and
  /// returns the path it landed at (`Download/Lens Lite/<title>.pdf`).
  ///
  /// Not recorded in the history: the scan itself is the image.
  Future<String> savePdf(
    List<Uint8List> pages, {
    required String title,
  }) async {
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final name = fileStem(title);
    try {
      final pdf = await NativeImageKit.writePdf(
        pages: pages,
        name: name,
        folder: pdfFolder,
      );
      return '${pdf.location}/${pdf.name}';
    } on PlatformException catch (error) {
      // API 24-28 writes to the public Downloads directory, which needs the
      // legacy storage grant. Q and later go through MediaStore, no grant.
      if (error.code != 'storage_permission') rethrow;
      if (!await Permission.storage.request().isGranted) {
        throw const FileSystemException(
          'Storage permission is required to save the PDF.',
        );
      }
      final pdf = await NativeImageKit.writePdf(
        pages: pages,
        name: name,
        folder: pdfFolder,
      );
      return '${pdf.location}/${pdf.name}';
    }
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

  /// A file in app storage named after [title], with a numeric suffix when that
  /// name is already taken.
  File _freeFile(String title, String extension) {
    final stem = fileStem(title);
    var candidate = File(p.join(storageDirectory.path, '$stem$extension'));
    for (var index = 2; candidate.existsSync(); index++) {
      candidate = File(p.join(storageDirectory.path, '$stem ($index)$extension'));
    }
    return candidate;
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
