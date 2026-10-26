import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/services/scan_exporter.dart';
import 'package:path/path.dart' as p;

Uint8List fakeJpeg() {
  final image = img.Image(width: 320, height: 240);
  return Uint8List.fromList(img.encodeJpg(image));
}

/// PDF assembly and thumbnailing live in `LensImageKit` on the Android side.
/// The unit tests stand in for the platform with a channel mock so the
/// bookkeeping this class actually owns stays covered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('lens_lite/image');
  late Directory tempDir;
  late InMemoryScanRepository repository;
  late ScanExporter exporter;
  late List<Map<Object?, Object?>> pdfCalls;

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
    pdfCalls = <Map<Object?, Object?>>[];

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
          final arguments = call.arguments as Map<Object?, Object?>;
          pdfCalls.add(arguments);
          final name = arguments['name'] as String;
          final folder = arguments['folder'] as String;
          // The native side writes the record copy as it publishes the export.
          final record = arguments['recordPath'] as String?;
          if (record != null) {
            File(record)
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync(<int>[...'%PDF-1.4\n'.codeUnits]);
          }
          return <String, dynamic>{
            'name': '$name.pdf',
            'location': 'Download/$folder',
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

  test('saveImage names the file after the scan and records a row', () async {
    final entry = await exporter.saveImage(fakeJpeg(), title: 'My capture');

    expect(entry.id, isNotNull);
    expect(entry.kind, 'image');
    expect(entry.title, 'My capture');
    expect(p.basename(entry.filePath), 'My capture.jpg');
    expect(File(entry.filePath).existsSync(), isTrue);
    expect(entry.thumbPath, isNotNull);
    expect(File(entry.thumbPath!).existsSync(), isTrue);

    final history = await repository.all();
    expect(history, hasLength(1));
    expect(history.first.title, 'My capture');
  });

  test('a repeated title does not overwrite the earlier file', () async {
    final first = await exporter.saveImage(fakeJpeg(), title: 'Save');
    final second = await exporter.saveImage(fakeJpeg(), title: 'Save');

    expect(p.basename(first.filePath), 'Save.jpg');
    expect(p.basename(second.filePath), 'Save (2).jpg');
    expect(File(first.filePath).existsSync(), isTrue);
  });

  test('fileStem removes what a filesystem cannot hold', () {
    expect(
      ScanExporter.fileStem('Scan 24 Oct 2026, 10:32'),
      'Scan 24 Oct 2026, 10:32',
    );
    expect(
      ScanExporter.fileStem('a/b\\c*d?e"f<g>h|i'),
      'a b c d e f g h i',
    );
    expect(ScanExporter.fileStem('   '), 'Scan');
    expect(ScanExporter.fileStem('.hidden.'), 'hidden');
  });

  test('savePdf keeps a record and publishes a copy to Downloads', () async {
    final pages = <Uint8List>[fakeJpeg(), fakeJpeg(), fakeJpeg()];
    final path = await exporter.savePdf(pages, title: 'Three pages');

    expect(path, 'Download/Lens Lite/Three pages.pdf');
    expect(pdfCalls, hasLength(1));
    expect((pdfCalls.single['pages'] as List).length, 3);
    expect(pdfCalls.single['name'], 'Three pages');
    expect(pdfCalls.single['folder'], 'Lens Lite');

    // The app's own copy is the tile; the Downloads copy is the export.
    final scans = await repository.all();
    expect(scans, hasLength(1));
    expect(scans.single.kind, 'pdf');
    expect(scans.single.title, 'Three pages');
    expect(p.basename(scans.single.filePath), 'Three pages.pdf');
    expect(pdfCalls.single['recordPath'], scans.single.filePath);
    expect(File(scans.single.filePath).existsSync(), isTrue);
    expect(scans.single.thumbPath, isNotNull);
  });

  test('a repeated PDF title does not overwrite the earlier record', () async {
    await exporter.savePdf(<Uint8List>[fakeJpeg()], title: 'Report');
    final second = await exporter.savePdf(<Uint8List>[fakeJpeg()], title: 'Report');

    final scans = await repository.all();
    expect(scans, hasLength(2));
    expect(
      scans.map((entry) => p.basename(entry.filePath)).toSet(),
      {'Report.pdf', 'Report (2).pdf'},
    );
    // The export keeps the plain name; MediaStore dedupes its own copies.
    expect(second, 'Download/Lens Lite/Report.pdf');
  });

  test('savePdf rejects an empty page list', () {
    expect(
      () => exporter.savePdf(<Uint8List>[], title: 'Empty'),
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
