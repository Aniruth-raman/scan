import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  ScanExporter exporterFor(ScanRepository repository) => ScanExporter(
        repository: repository,
        storageDirectory: tempDir,
      );

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

  testWidgets('shows the empty state when nothing is scanned yet',
      (tester) async {
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
