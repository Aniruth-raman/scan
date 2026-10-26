import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/models/scan_entry.dart';
import 'package:lens_lite/screens/history_screen.dart';
import 'package:lens_lite/services/scan_exporter.dart';

/// On-device end-to-end check of the shipped flow:
/// My Scans -> capture -> crop -> review -> save.
///
/// The camera screen repaints every analysed frame, so nothing here uses
/// `pumpAndSettle` while the viewfinder is live — it would never settle.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The shutter is a painted ring; it is reached through its semantics label.
  final shutter = find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == 'Capture',
  );

  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return finder.evaluate().isNotEmpty;
  }

  Future<bool> waitUntilGone(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isEmpty) return true;
    }
    return finder.evaluate().isEmpty;
  }

  Future<ScanRepository> pumpApp(WidgetTester tester) async {
    final repository = SqfliteScanRepository();
    final documents = await getApplicationDocumentsDirectory();
    final storage = Directory(p.join(documents.path, 'scans'));
    await storage.create(recursive: true);
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          repository: repository,
          exporter: ScanExporter(
            repository: repository,
            storageDirectory: storage,
          ),
        ),
      ),
    );
    await waitFor(tester, find.text('My Scans'));
    return repository;
  }

  /// Auto capture would fire on its own while the test is still setting up, so
  /// the flows turn it off the way a user would: More options -> Auto capture.
  Future<void> disableAutoCapture(WidgetTester tester) async {
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'More options',
      ),
    );
    await waitFor(tester, find.text('Auto capture'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Auto capture'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(20, 40));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Capture one page and leave the app on the review stage.
  Future<void> captureToReview(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.photo_camera));
    expect(
      await waitFor(tester, find.byType(CameraPreview)),
      isTrue,
      reason: 'camera preview never appeared',
    );
    // Let the detector find the page so the crop stage starts from a quad.
    await tester.pump(const Duration(seconds: 2));
    await disableAutoCapture(tester);

    await tester.tap(shutter);
    expect(
      await waitFor(tester, find.text('Review and Edit')),
      isTrue,
      reason: 'the shutter did not reach the crop stage',
    );
    // The crop stage decodes and detects before its hero does anything.
    expect(
      await waitUntilGone(tester, find.byType(CircularProgressIndicator)),
      isTrue,
      reason: 'the crop preview never finished loading',
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Review and Edit'));
    expect(
      await waitFor(tester, find.text('Finish')),
      isTrue,
      reason: 'the crop stage did not reach review',
    );
  }

  testWidgets('capture reaches review and saves an image', (tester) async {
    final repository = await pumpApp(tester);
    final before = await repository.all();

    await captureToReview(tester);

    await tester.tap(find.text('Finish'));
    expect(
      await waitFor(tester, find.text('My Scans')),
      isTrue,
      reason: 'Finish did not return to My Scans',
    );

    final after = await repository.all();
    final saved = after.length - before.length;
    // ignore: avoid_print
    print('FLOW image: +$saved rows, newest=${after.first.title} '
        '${after.first.kind} ${p.basename(after.first.filePath)}');
    expect(saved, 1, reason: 'an image save should record exactly one row');
    expect(after.first.isPdf, isFalse);
    expect(File(after.first.filePath).existsSync(), isTrue);
    expect(after.first.thumbPath, isNotNull);
  });

  testWidgets('a PDF save records its own tile', (tester) async {
    final repository = await pumpApp(tester);
    final before = await repository.all();

    await captureToReview(tester);

    await tester.tap(find.text('Options'));
    await waitFor(tester, find.text('TITLE'));
    // The SAVE AS rows sit below the 160 dp peek.
    await tester.drag(find.text('TITLE'), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('PDF'));
    await tester.pump(const Duration(milliseconds: 400));
    // Tap the scrim above the sheet to close it.
    await tester.tapAt(const Offset(20, 40));
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.text('Finish'));
    expect(
      await waitFor(tester, find.text('My Scans')),
      isTrue,
      reason: 'Finish did not return to My Scans',
    );

    final after = await repository.all();
    final added = after.sublist(0, after.length - before.length);
    // ignore: avoid_print
    print('FLOW pdf: ${added.map((entry) => '${entry.kind}:'
        '${p.basename(entry.filePath)}').join(', ')}');
    expect(added, hasLength(2), reason: 'image and PDF each get a record');
    expect(added.where((entry) => entry.isPdf), hasLength(1));
    final ScanEntry pdf = added.firstWhere((entry) => entry.isPdf);
    expect(File(pdf.filePath).existsSync(), isTrue);
    expect(p.basename(pdf.filePath), endsWith('.pdf'));
  });
}
