import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/services/scan_exporter.dart';

Uint8List fakeJpeg() {
  final image = img.Image(width: 320, height: 240);
  return Uint8List.fromList(img.encodeJpg(image));
}

/// PDF assembly and thumbnailing moved to `LensImageKit` on the Android side.
/// The unit tests stand in for the platform with a channel mock so the
/// bookkeeping this class actually owns stays covered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lens_lite/image');
  late Directory tempDir;
  late InMemoryScanRepository repository;
  late ScanExporter exporter;

  setUpAll(() {
    // NativeImageKit is Android-only; the guard reads defaultTargetPlatform.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lens_lite_export');
    repository = InMemoryScanRepository();
    exporter = ScanExporter(repository: repository, storageDirectory: tempDir);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'thumbnail':
              return <String, dynamic>{
                'bytes': Uint8List.fromList(<int>[1, 2, 3]),
                'width': 32,
                'height': 24,
              };
            case 'writePdf':
              final path = (call.arguments as Map)['path'] as String;
              final pages = (call.arguments as Map)['pages'] as List;
              // Emit a minimal but structurally real PDF header.
              final bytes = <int>[
                ...'%PDF-1.4\n'.codeUnits,
                ...'%pages:${pages.length}\n'.codeUnits,
              ];
              File(path).writeAsBytesSync(bytes);
              return <String, dynamic>{
                'path': path,
                'bytes': bytes.length,
                'pages': pages.length,
              };
            default:
              return null;
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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

  test('exportPdf writes a PDF through the platform and records a row', () async {
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

  test('exportPdfPages sends every page to the platform', () async {
    final pages = <Uint8List>[fakeJpeg(), fakeJpeg(), fakeJpeg()];
    final entry = await exporter.exportPdfPages(pages, title: 'Three pages');

    expect(entry.kind, 'pdf');
    expect(entry.title, 'Three pages');

    final saved = await File(entry.filePath).readAsBytes();
    expect(String.fromCharCodes(saved), contains('%pages:3'));
  });

  test('exportPdfPages rejects an empty page list', () async {
    expect(
      () => exporter.exportPdfPages(<Uint8List>[].cast<Uint8List>()),
      throwsArgumentError,
    );
  });

  test('delete removes the row and the files from disk', () async {
    final entry = await exporter.saveImage(fakeJpeg(), title: 'Doomed');
    await exporter.delete(entry);

    expect(File(entry.filePath).existsSync(), isFalse);
    expect(File(entry.thumbPath!).existsSync(), isFalse);
    expect(await repository.all(), isEmpty);
  });
}
