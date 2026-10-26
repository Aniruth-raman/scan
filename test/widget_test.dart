import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/models/scan_entry.dart';
import 'package:lens_lite/screens/history_screen.dart';
import 'package:lens_lite/services/scan_exporter.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lens_lite_widget');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ScanExporter exporterFor(ScanRepository repository) =>
      ScanExporter(repository: repository, storageDirectory: tempDir);

  testWidgets('renders seeded scans as a two-column grid', (tester) async {
    final repository = InMemoryScanRepository(
      seed: [
        ScanEntry(
          title: 'Receipt',
          kind: 'image',
          filePath: '/tmp/receipt.jpg',
          createdAt: DateTime(2026, 10, 24, 10, 0),
        ),
        ScanEntry(
          title: 'Whiteboard',
          kind: 'pdf',
          filePath: '/tmp/whiteboard.pdf',
          createdAt: DateTime(2026, 10, 23, 9, 0),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My Scans'), findsOneWidget);
    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Whiteboard'), findsOneWidget);
    // PDFs are flagged with the badge rather than a text label.
    expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
    // The capture affordance is the 48 dp circle, not a Material FAB.
    expect(find.byIcon(Icons.photo_camera), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the scan menu names where the file went', (tester) async {
    final repository = InMemoryScanRepository(
      seed: [
        ScanEntry(
          title: 'Receipt',
          kind: 'image',
          filePath: '/tmp/receipt.jpg',
          createdAt: DateTime(2026, 10, 24, 10, 0),
        ),
        ScanEntry(
          title: 'Contract',
          kind: 'pdf',
          filePath: '/tmp/contract.pdf',
          createdAt: DateTime(2026, 10, 23, 9, 0),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The image tile's overflow opens the menu; the band names the album.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Phone Storage > Pictures > Lens Lite'), findsOneWidget);

    // Dismiss and do the same for the PDF, which goes to Downloads.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Phone Storage > Download > Lens Lite'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('files in the shared folders are listed once, and only hidden', (
    tester,
  ) async {
    // The reference viewport, so all three tiles are on screen.
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('lens_lite/image');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Gallery access is granted in this scenario, so the indexer runs.
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    messenger.setMockMethodCallHandler(permissions, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 1; // granted
        case 'requestPermissions':
          return <int, int>{17: 1};
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));
    final thumb = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 8, height: 8)),
    );
    // Indexer: a file dropped into the album, a PDF in Downloads, and the app's
    // own export for `Receipt` (same URI the record kept).
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'listShared') return null;
      return <Map<String, Object?>>[
        {
          'uri': 'content://media/external/images/media/13',
          'name': 'Receipt.jpg',
          'mime': 'image/jpeg',
          'modified': 3000,
          'size': 10,
          'thumb': thumb,
        },
        {
          'uri': 'content://media/external/downloads/12',
          'name': 'Invoice.pdf',
          'mime': 'application/pdf',
          'modified': 2000,
          'size': 10,
        },
        {
          'uri': 'content://media/external/images/media/11',
          'name': 'Dropped.jpg',
          'mime': 'image/jpeg',
          'modified': 1000,
          'size': 10,
          'thumb': thumb,
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final repository = InMemoryScanRepository(
      seed: [
        ScanEntry(
          title: 'Receipt',
          kind: 'image',
          filePath: '/tmp/receipt.jpg',
          sharedUri: 'content://media/external/images/media/13',
          createdAt: DateTime(2026, 10, 24, 10, 0),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The owned receipt is one tile even though the album has its copy too.
    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Invoice'), findsOneWidget);
    expect(find.text('Dropped'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNWidgets(3));

    // Removing an imported file hides it for this screen; the file stays, and
    // the dismissal is not remembered anywhere.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Remove from My Scans'), findsOneWidget);
    await tester.tap(find.text('Remove from My Scans'));
    await tester.pumpAndSettle();

    expect(find.text('Dropped'), findsNothing);
    expect((await repository.all()).single.title, 'Receipt');
    expect(tester.takeException(), isNull);

    // A fresh screen is a fresh list: the file shows up again, as in the
    // original.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dropped'), findsOneWidget);
  });

  testWidgets('a legacy record is not duplicated by its album copy', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async => 1);
    addTearDown(() => messenger.setMockMethodCallHandler(permissions, null));

    const channel = MethodChannel('lens_lite/image');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'listShared') return null;
      // The album copy of a row saved before `sharedUri` existed. MediaStore
      // turned the colon into an underscore.
      return <Map<String, Object?>>[
        {
          'uri': 'content://media/external/images/media/21',
          'name': 'Scan Oct 26, 2026 10_32 PM.jpg',
          'mime': 'image/jpeg',
          'modified': 5000,
          'size': 10,
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final repository = InMemoryScanRepository(
      seed: [
        ScanEntry(
          title: 'Scan Oct 26, 2026 10:32 PM',
          kind: 'image',
          filePath: '/tmp/scan.jpg',
          createdAt: DateTime(2026, 10, 26, 22, 32),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One tile: the record. The album copy with the mangled name stays hidden.
    expect(find.text('Scan Oct 26, 2026 10:32 PM'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the empty state when nothing is scanned yet', (
    tester,
  ) async {
    final repository = InMemoryScanRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: exporterFor(repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No scans yet'), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
