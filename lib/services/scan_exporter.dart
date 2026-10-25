import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/scan_repository.dart';
import '../models/scan_entry.dart';

/// Turns captured camera bytes into a saved image or an exported PDF and
/// records the result in the scan history — the flow this app is modeled on:
/// capture -> export (image | PDF) -> tracked in "My Scans".
class ScanExporter {
  ScanExporter({required this.repository, required this.storageDirectory});

  final ScanRepository repository;
  final Directory storageDirectory;

  /// Default file name, matching the original's date-based naming.
  static String defaultTitle(DateTime when) =>
      'Scan ${DateFormat.yMMMd().add_jm().format(when)}';

  /// Builds a one-page A4 PDF embedding [imageBytes] with a title and date
  /// header. Pure Dart (pdf package) — no platform channel involved.
  static Future<Uint8List> buildPdf({
    required Uint8List imageBytes,
    required String title,
    required DateTime timestamp,
  }) async {
    final doc = pw.Document(title: title);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              DateFormat.yMMMd().add_jm().format(timestamp),
              style: const pw.TextStyle(
                fontSize: 11,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Expanded(
              child: pw.Center(
                child: pw.Image(
                  pw.MemoryImage(imageBytes),
                  fit: pw.BoxFit.contain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Uint8List.fromList(await doc.save());
  }

  /// Saves the captured frame as a JPEG in app storage and tracks it.
  Future<ScanEntry> saveImage(Uint8List bytes, {String? title}) async {
    final now = DateTime.now();
    final path = p.join(
      storageDirectory.path,
      'scan_${now.microsecondsSinceEpoch}.jpg',
    );
    await File(path).writeAsBytes(bytes, flush: true);
    final thumbPath = await _writeThumbnail(bytes, now);
    final entry = ScanEntry(
      title: title ?? defaultTitle(now),
      kind: 'image',
      filePath: path,
      thumbPath: thumbPath,
      createdAt: now,
    );
    return repository.insert(entry);
  }

  /// Exports the captured frame as a PDF in app storage and tracks it.
  Future<ScanEntry> exportPdf(Uint8List imageBytes, {String? title}) async {
    final now = DateTime.now();
    final effectiveTitle = title ?? defaultTitle(now);
    final pdfBytes = await buildPdf(
      imageBytes: imageBytes,
      title: effectiveTitle,
      timestamp: now,
    );
    final path = p.join(
      storageDirectory.path,
      'scan_${now.microsecondsSinceEpoch}.pdf',
    );
    await File(path).writeAsBytes(pdfBytes, flush: true);
    final thumbPath = await _writeThumbnail(imageBytes, now);
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
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final thumb = img.copyResize(decoded, width: 320);
    final path = p.join(
      storageDirectory.path,
      'thumb_${stamp.microsecondsSinceEpoch}.jpg',
    );
    await File(path)
        .writeAsBytes(img.encodeJpg(thumb, quality: 80), flush: true);
    return path;
  }
}