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
/// Every save writes two copies, the way the original does: a private record
/// (what the scan list opens and shares) and a copy in shared storage the user
/// can reach from any file manager. The content URI of the shared copy is kept
/// on the entry, so deleting the scan removes that exact file — and so the
/// folder indexer knows the file is already represented.
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

  /// `Pictures/<folder>` on the platform side, the gallery album.
  static const imageFolder = 'Lens Lite';

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

  /// Saves one page as a JPEG: a private record and a gallery copy.
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
    final published = await _publishWithRetry(
      () => NativeImageKit.publishImage(
        pageBytes,
        name: fileStem(effectiveTitle),
        folder: imageFolder,
      ),
    );
    final thumbPath = await _writeThumbnail(pageBytes, now);
    final entry = ScanEntry(
      title: effectiveTitle,
      kind: 'image',
      filePath: file.path,
      thumbPath: thumbPath,
      sharedUri: published.uri,
      createdAt: now,
    );
    return repository.insert(entry);
  }

  /// Writes one PDF for [pages] named after [title] in two places: a record in
  /// app storage (the tile) and a copy in `Download/Lens Lite`.
  ///
  /// Returns the export's location (`Download/Lens Lite/<title>.pdf`).
  Future<String> savePdf(List<Uint8List> pages, {required String title}) async {
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'must not be empty');
    }
    final now = DateTime.now();
    final file = _freeFile(title, '.pdf');
    final published = await _publishWithRetry(
      () => NativeImageKit.writePdf(
        pages: pages,
        name: fileStem(title),
        folder: pdfFolder,
        recordPath: file.path,
      ),
    );

    final thumbPath = await _writeThumbnail(pages.first, now);
    await repository.insert(
      ScanEntry(
        title: title,
        kind: 'pdf',
        filePath: file.path,
        thumbPath: thumbPath,
        sharedUri: published.uri,
        createdAt: now,
      ),
    );
    return '${published.location}/${published.name}';
  }

  /// Removes a scan: the record, its private files, and the shared copy this app
  /// published. Files that were never ours are not touched (see [deleteImported]).
  Future<void> delete(ScanEntry entry) async {
    if (entry.id != null) await repository.delete(entry.id!);
    final files = <File>[File(entry.filePath)];
    final thumb = entry.thumbPath;
    if (thumb != null) files.add(File(thumb));
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    final shared = entry.sharedUri;
    if (shared != null) {
      try {
        await NativeImageKit.deleteShared(<String>[shared]);
      } catch (_) {
        // The shared copy may already be gone; the record is what matters.
      }
    }
  }

  /// Drops an indexed file from the list without touching it on disk, the way
  /// the original treats files it did not create.
  Future<void> deleteImported(String uri) => repository.hideMedia(uri);

  /// A file in app storage named after [title], with a numeric suffix when that
  /// name is already taken.
  File _freeFile(String title, String extension) {
    final stem = fileStem(title);
    var candidate = File(p.join(storageDirectory.path, '$stem$extension'));
    for (var index = 2; candidate.existsSync(); index++) {
      candidate = File(
        p.join(storageDirectory.path, '$stem ($index)$extension'),
      );
    }
    return candidate;
  }

  /// API 24-28 have no MediaStore collections, so publishing writes into the
  /// public directory and needs the legacy grant. Q and later need nothing.
  Future<T> _publishWithRetry<T>(Future<T> Function() publish) async {
    try {
      return await publish();
    } on PlatformException catch (error) {
      if (error.code != 'storage_permission') rethrow;
      if (!await Permission.storage.request().isGranted) {
        throw const FileSystemException(
          'Storage permission is required to save outside the app.',
        );
      }
      return publish();
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
