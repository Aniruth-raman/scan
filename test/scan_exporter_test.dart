import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/services/scan_exporter.dart';

Uint8List fakeJpeg() {
  final image = img.Image(width: 320, height: 240);
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  late Directory tempDir;
  late InMemoryScanRepository repository;
  late ScanExporter exporter;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lens_lite_export');
    repository = InMemoryScanRepository();
    exporter = ScanExporter(repository: repository, storageDirectory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('buildPdf produces a real PDF document', () async {
    final bytes = await ScanExporter.buildPdf(
      imageBytes: fakeJpeg(),
      title: 'Test scan',
      timestamp: DateTime(2026, 10, 24, 10, 30),
    );

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
  });

  test('saveImage stores the file, a thumbnail and a history row', () async {
    final entry = await exporter.saveImage(fakeJpeg(), title: 'My capture');

    expect(entry.id, isNotNull);
    expect(entry.kind, 'image');
    expect(entry.title, 'My capture');
    expect(File(entry.filePath).existsSync(), isTrue);
    expect(entry.thumbPath, isNotNull);
    expect(File(entry.thumbPath!).existsSync(), isTrue);

    final history = await repository.all();
    expect(history, hasLength(1));
    expect(history.first.title, 'My capture');
  });

  test('exportPdf stores a PDF file and a history row', () async {
    final entry = await exporter.exportPdf(fakeJpeg());

    expect(entry.kind, 'pdf');
    expect(entry.filePath, endsWith('.pdf'));
    expect(entry.title, startsWith('Scan '));

    final saved = await File(entry.filePath).readAsBytes();
    expect(String.fromCharCodes(saved.sublist(0, 5)), '%PDF-');

    final history = await repository.all();
    expect(history, hasLength(1));
    expect(history.first.kind, 'pdf');
  });

  test('delete removes the row and the files from disk', () async {
    final entry = await exporter.saveImage(fakeJpeg(), title: 'Doomed');
    await exporter.delete(entry);

    expect(File(entry.filePath).existsSync(), isFalse);
    expect(File(entry.thumbPath!).existsSync(), isFalse);
    expect(await repository.all(), isEmpty);
  });
}