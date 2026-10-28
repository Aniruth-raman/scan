import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scan/data/scan_repository.dart';
import 'package:scan/design/scan_tokens.dart';
import 'package:scan/screens/review_screen.dart';
import 'package:scan/services/scan_exporter.dart';
import 'package:path/path.dart' as p;

Uint8List fakeJpeg({int width = 320, int height = 240}) {
  final image = img.Image(width: width, height: height);
  return Uint8List.fromList(img.encodeJpg(image));
}

/// Review & Edit is measured from `ui-edit.xml` on the 384 x 832 dp reference
/// viewport, so the geometry assertions below are the numbers the layout was
/// built from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const imageChannel = MethodChannel('scan/image');

  late Directory tempDir;
  late ScanExporter exporter;
  late InMemoryScanRepository repository;
  late List<String> nativeCalls;
  late List<Map<Object?, Object?>> pdfCalls;
  late bool publishFails;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('scan_review');
    repository = InMemoryScanRepository();
    exporter = ScanExporter(repository: repository, storageDirectory: tempDir);
    nativeCalls = <String>[];
    pdfCalls = <Map<Object?, Object?>>[];
    publishFails = false;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(imageChannel, (call) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'thumbnail':
          return <String, dynamic>{
            'bytes': Uint8List.fromList(<int>[1, 2, 3]),
            'width': 32,
            'height': 24,
          };
        case 'setJpegDpi':
          return true;
        case 'transform':
          return <String, dynamic>{
            'bytes': Uint8List.fromList(<int>[4, 5, 6]),
            'width': 320,
            'height': 240,
          };
        case 'publishImage':
          if (publishFails) {
            throw PlatformException(
              code: 'scan_image_kit',
              message: 'no space',
            );
          }
          final imageName =
              (call.arguments as Map<Object?, Object?>)['name'] as String;
          return <String, dynamic>{
            'uri': 'content://media/external/images/media/$imageName',
            'name': '$imageName.jpg',
            'location': 'Pictures/Scan',
          };
        case 'writePdf':
          final arguments = call.arguments as Map<Object?, Object?>;
          pdfCalls.add(arguments);
          return <String, dynamic>{
            'uri': 'content://media/external/downloads/${arguments['name']}',
            'name': '${arguments['name']}.pdf',
            'location': 'Download/${arguments['folder']}',
          };
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(imageChannel, null);
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // A pending write can still hold the directory on Windows.
    }
  });

  /// `NativeImageKit` is Android-only; the override has to be cleared inside
  /// the test body because flutter_test verifies debug variables at the end.
  Future<void> onAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpReview(
    WidgetTester tester,
    List<Uint8List> pages, {
    ValueChanged<ReviewResult?>? onResult,
  }) async {
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final result = await Navigator.push<ReviewResult>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ReviewScreen(pages: pages, exporter: exporter),
                    ),
                  );
                  onResult?.call(result);
                },
                child: const Text('open review'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the measured editor chrome', (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);

    expect(find.text('Options'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
    expect(find.text('Reorder'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    // The tray is icon-only in the editor; its labels are semantics.
    expect(find.byIcon(Icons.rotate_right), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // 344 x 40 dp accent pill, 20 dp in from both edges. The pill is centred in
    // a 48 dp container that sits 20 dp above the screen edge.
    final pill = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.color == ScanColor.accent,
      ),
    );
    expect(pill.width, closeTo(344, 0.5));
    expect(pill.height, closeTo(40, 0.5));
    expect(pill.left, closeTo(20, 0.5));
    expect(pill.bottom, closeTo(832 - 24, 0.5));

    // 48 x 144 dp tray (three actions), 12 dp from the end edge, centred on the
    // content column.
    final tray = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                ScanColor.editorTrayFill,
      ),
    );
    expect(tray.width, closeTo(48, 0.5));
    expect(tray.height, closeTo(144, 0.5));
    expect(tray.right, closeTo(384 - 12, 0.5));

    // Two equal cells across the 360 dp row: each label sits on its centre.
    expect(tester.getCenter(find.text('Reorder')).dx, closeTo(102, 1));
    expect(tester.getCenter(find.text('Add')).dx, closeTo(282, 1));

    // 48 dp top bar with the back glyph on its centre line.
    expect(tester.getCenter(find.byIcon(Icons.arrow_back)).dy, closeTo(24, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single page shows no page chip', (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);
    expect(find.text('1/1'), findsNothing);
  });

  testWidgets('the page chip tracks the pager', (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg(), fakeJpeg()]);
    expect(find.text('1/2'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotate previews without touching the encoder', (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.rotate_right));
    await tester.pumpAndSettle();

    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(nativeCalls, isEmpty, reason: 'rotate must not re-encode the page');
  });

  testWidgets('delete is disabled while the session has one page', (
    tester,
  ) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete drops the current page when there are several', (
    tester,
  ) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg(), fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    final delegate = pageView.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 1);
    expect(tester.takeException(), isNull);
  });

  /// Renames the document through the options sheet, the way a user does.
  Future<void> renameVia(WidgetTester tester, String name) async {
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Scan '));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), name);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    // Dismiss the sheet; the title is committed as it closes.
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();
  }

  /// The page is written to the file system, which only advances on the real
  /// event loop.
  Future<void> finish(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Finish'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Finish saves the image under the renamed scan', (tester) async {
    await onAndroid(() async {
      ReviewResult? result;
      await pumpReview(tester, <Uint8List>[
        fakeJpeg(),
      ], onResult: (value) => result = value);
      await renameVia(tester, 'save');

      await finish(tester);

      expect(nativeCalls, contains('thumbnail'));
      // The file carries the name the user typed, not a timestamp.
      expect(
        File(p.join(tempDir.path, 'save.jpg')).existsSync(),
        isTrue,
        reason: 'saved as ${tempDir.listSync().map((f) => f.path)}',
      );
      expect((await repository.all()).single.title, 'save');
      expect(result?.message, 'Saved to Gallery');
    });
  });

  testWidgets('a failed publish keeps the review open with an error', (
    tester,
  ) async {
    await onAndroid(() async {
      publishFails = true;
      ReviewResult? result;
      await pumpReview(tester, <Uint8List>[
        fakeJpeg(),
      ], onResult: (value) => result = value);
      await renameVia(tester, 'save');

      await finish(tester);

      // Nothing was recorded and the stage is still up, showing why.
      expect(result, isNull);
      expect(await repository.all(), isEmpty);
      expect(find.textContaining('Could not save'), findsOneWidget);
    });
  });

  testWidgets('edits are baked through the native transform once', (
    tester,
  ) async {
    await onAndroid(() async {
      await pumpReview(tester, <Uint8List>[fakeJpeg()]);

      await tester.tap(find.byIcon(Icons.rotate_right));
      await tester.pumpAndSettle();

      // Editing is state only: nothing is re-encoded until the page is saved.
      expect(nativeCalls.where((call) => call == 'transform'), isEmpty);

      await finish(tester);

      expect(nativeCalls.where((call) => call == 'transform'), hasLength(1));
    });
  });

  testWidgets('image + PDF produce one tile each, both named after the scan', (
    tester,
  ) async {
    await onAndroid(() async {
      ReviewResult? result;
      await pumpReview(tester, <Uint8List>[
        fakeJpeg(),
      ], onResult: (value) => result = value);
      await renameVia(tester, 'Q4 report');

      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('TITLE'), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PDF'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();

      await finish(tester);

      expect(pdfCalls, hasLength(1));
      expect(pdfCalls.single['name'], 'Q4 report');
      expect(pdfCalls.single['folder'], 'Scan');
      expect(
        result?.message,
        'Saved to Gallery · PDF: Download/Scan/Q4 report.pdf',
      );

      // Both targets produce their own record, like the original: a JPEG tile
      // and a PDF tile.
      final scans = await repository.all();
      expect(scans, hasLength(2));
      expect(scans.map((entry) => entry.kind).toSet(), {'image', 'pdf'});
      expect(
        p.basename(scans.firstWhere((entry) => entry.isPdf).filePath),
        'Q4 report.pdf',
      );
      expect(
        p.basename(scans.firstWhere((entry) => !entry.isPdf).filePath),
        'Q4 report.jpg',
      );
    });
  });

  testWidgets('a PDF-only save still produces its tile', (tester) async {
    await onAndroid(() async {
      ReviewResult? result;
      await pumpReview(tester, <Uint8List>[
        fakeJpeg(),
      ], onResult: (value) => result = value);
      await renameVia(tester, 'Q4 report');

      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('TITLE'), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Image')); // untick the JPEG
      await tester.pumpAndSettle();
      await tester.tap(find.text('PDF'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();

      await finish(tester);

      final scans = await repository.all();
      expect(scans, hasLength(1));
      expect(scans.single.isPdf, isTrue);
      expect(result?.message, 'PDF: Download/Scan/Q4 report.pdf');
    });
  });
}
