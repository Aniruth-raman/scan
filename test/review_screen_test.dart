import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/design/lens_tokens.dart';
import 'package:lens_lite/screens/review_screen.dart';
import 'package:lens_lite/services/scan_exporter.dart';
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

  const imageChannel = MethodChannel('lens_lite/image');
  const galChannel = MethodChannel('gal');

  late Directory tempDir;
  late ScanExporter exporter;
  late InMemoryScanRepository repository;
  late List<String> nativeCalls;
  late List<Map<Object?, Object?>> pdfCalls;
  late bool galleryGranted;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lens_lite_review');
    repository = InMemoryScanRepository();
    exporter = ScanExporter(repository: repository, storageDirectory: tempDir);
    nativeCalls = <String>[];
    pdfCalls = <Map<Object?, Object?>>[];
    galleryGranted = true;

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
        case 'transform':
          return <String, dynamic>{
            'bytes': Uint8List.fromList(<int>[4, 5, 6]),
            'width': 320,
            'height': 240,
          };
        case 'writePdf':
          final arguments = call.arguments as Map<Object?, Object?>;
          pdfCalls.add(arguments);
          return <String, dynamic>{
            'name': '${arguments['name']}.pdf',
            'location': 'Download/${arguments['folder']}',
          };
        default:
          throw MissingPluginException(call.method);
      }
    });
    // The gallery plugin is not under test; stand in for the platform.
    messenger.setMockMethodCallHandler(galChannel, (call) async {
      switch (call.method) {
        case 'hasAccess':
        case 'requestAccess':
          return galleryGranted;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(imageChannel, null);
    messenger.setMockMethodCallHandler(galChannel, null);
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
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('Reorder'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    // The tray is icon-only in the editor; its labels are semantics.
    expect(find.byIcon(Icons.crop), findsOneWidget);
    expect(find.byIcon(Icons.rotate_right), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // 344 x 40 dp accent pill, 20 dp in from both edges. The pill is centred in
    // a 48 dp container that sits 20 dp above the screen edge.
    final pill = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.color == LensColor.accent,
      ),
    );
    expect(pill.width, closeTo(344, 0.5));
    expect(pill.height, closeTo(40, 0.5));
    expect(pill.left, closeTo(20, 0.5));
    expect(pill.bottom, closeTo(832 - 24, 0.5));

    // 48 x 192 dp tray, 12 dp from the end edge, centred on the content column.
    final tray = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                LensColor.editorTrayFill,
      ),
    );
    expect(tray.width, closeTo(48, 0.5));
    expect(tray.height, closeTo(192, 0.5));
    expect(tray.right, closeTo(384 - 12, 0.5));

    // Three 120 dp cells: the labels sit on the cell centres.
    expect(tester.getCenter(find.text('Filters')).dx, closeTo(72, 1));
    expect(tester.getCenter(find.text('Reorder')).dx, closeTo(192, 1));
    expect(tester.getCenter(find.text('Add')).dx, closeTo(312, 1));

    // 48 dp top bar with the back glyph on its centre line.
    expect(tester.getCenter(find.byIcon(Icons.arrow_back)).dy, closeTo(24, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotate previews without touching the encoder', (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.rotate_right));
    await tester.pumpAndSettle();

    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(nativeCalls, isEmpty, reason: 'rotate must not re-encode the page');
  });

  testWidgets('delete is disabled while the session has one page',
      (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete drops the current page when there are several',
      (tester) async {
    await pumpReview(tester, <Uint8List>[fakeJpeg(), fakeJpeg()]);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    final delegate = pageView.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Add hands the pages back to the capture session', (tester) async {
    ReviewResult? result;
    await pumpReview(
      tester,
      <Uint8List>[fakeJpeg()],
      onResult: (value) => result = value,
    );

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.addMore, isTrue);
    expect(result!.pages, hasLength(1));
    expect(nativeCalls, isEmpty, reason: 'an unedited page is already final');
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
      await pumpReview(
        tester,
        <Uint8List>[fakeJpeg()],
        onResult: (value) => result = value,
      );
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

  testWidgets('Finish falls back to My Scans when the gallery refuses',
      (tester) async {
    await onAndroid(() async {
      galleryGranted = false;
      ReviewResult? result;
      await pumpReview(
        tester,
        <Uint8List>[fakeJpeg()],
        onResult: (value) => result = value,
      );
      await renameVia(tester, 'save');

      await finish(tester);

      expect(result?.message, 'Saved to My Scans');
    });
  });

  testWidgets('an edited page is baked through the native transform once',
      (tester) async {
    await onAndroid(() async {
      await pumpReview(tester, <Uint8List>[fakeJpeg()]);

      await tester.tap(find.byIcon(Icons.rotate_right));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grayscale'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(nativeCalls, <String>['transform']);
    });
  });

  testWidgets('a PDF export takes the scan name and adds no second record',
      (tester) async {
    await onAndroid(() async {
      ReviewResult? result;
      await pumpReview(
        tester,
        <Uint8List>[fakeJpeg()],
        onResult: (value) => result = value,
      );
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
      expect(pdfCalls.single['folder'], 'Lens Lite');
      expect(
        result?.message,
        'Saved to Gallery · PDF: Download/Lens Lite/Q4 report.pdf',
      );

      // The JPEG is the record; the document is only an export.
      final scans = await repository.all();
      expect(scans, hasLength(1));
      expect(scans.single.kind, 'image');
      expect(p.basename(scans.single.filePath), 'Q4 report.jpg');
    });
  });
}
