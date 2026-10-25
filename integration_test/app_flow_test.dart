import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:lens_lite/data/scan_repository.dart';
import 'package:lens_lite/screens/history_screen.dart';
import 'package:lens_lite/services/scan_exporter.dart';

/// On-device end-to-end check of the capture flow:
/// My Scans -> live camera -> shutter -> corner adjust -> review -> save.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return finder.evaluate().isNotEmpty;
  }

  /// Waits until a button is both present and enabled (the crop action stays
  /// disabled while the capture preview is still being prepared).
  Future<bool> waitForEnabled(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (finder.evaluate().isEmpty) continue;
      final widget = tester.widget(finder);
      if (widget is ButtonStyleButton && widget.onPressed != null) return true;
    }
    return false;
  }

  testWidgets('capture flow reaches a live preview and saves a scan',
      (tester) async {
    final repository = SqfliteScanRepository();
    final documents = await getApplicationDocumentsDirectory();
    final storage = Directory(p.join(documents.path, 'scans'));
    await storage.create(recursive: true);
    final exporter =
        ScanExporter(repository: repository, storageDirectory: storage);

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(repository: repository, exporter: exporter),
      ),
    );
    // ignore: avoid_print
    print('FLOW step1 history pumped, fab='
        '${find.byType(FloatingActionButton).evaluate().length}');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final previewReady = await waitFor(tester, find.byType(CameraPreview));
    // ignore: avoid_print
    print('FLOW step2 camera preview visible: $previewReady '
        'errorIcon=${find.byIcon(Icons.no_photography).evaluate().length} '
        'spinner=${find.byType(CircularProgressIndicator).evaluate().length}');
    expect(previewReady, isTrue, reason: 'camera preview never became visible');

    // Let detection stream run for a moment.
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byIcon(Icons.camera));
    final adjustReady = await waitForEnabled(
      tester,
      find.widgetWithText(FilledButton, 'Done'),
    );
    // ignore: avoid_print
    print('FLOW step3 adjust screen ready: $adjustReady');
    expect(adjustReady, isTrue, reason: 'shutter did not reach the crop step');

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    final reviewReady = await waitFor(tester, find.text('Save to gallery'));
    // ignore: avoid_print
    print('FLOW step4 review visible: $reviewReady');
    expect(reviewReady, isTrue, reason: 'crop did not reach the review step');

    await tester.tap(find.text('Save to gallery'));
    final backHome = await waitFor(
      tester,
      find.byType(FloatingActionButton),
      timeout: const Duration(seconds: 30),
    );
    // ignore: avoid_print
    print('FLOW step5 back at history: $backHome');
    expect(backHome, isTrue, reason: 'save did not return to My Scans');

    final scans = await repository.all();
    // ignore: avoid_print
    print('FLOW scans in history: ${scans.length}');
    expect(scans, isNotEmpty, reason: 'saved scan was not recorded in history');
  });

  testWidgets('capture flow can export a PDF', (tester) async {
    final repository = SqfliteScanRepository();
    final documents = await getApplicationDocumentsDirectory();
    final storage = Directory(p.join(documents.path, 'scans'));
    await storage.create(recursive: true);
    final exporter =
        ScanExporter(repository: repository, storageDirectory: storage);

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(repository: repository, exporter: exporter),
      ),
    );
    await tester.tap(find.byType(FloatingActionButton));
    expect(
      await waitFor(tester, find.byType(CameraPreview)),
      isTrue,
      reason: 'camera preview never became visible',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.camera));
    final ready = await waitForEnabled(
      tester,
      find.widgetWithText(FilledButton, 'Done'),
    );
    expect(ready, isTrue, reason: 'crop step never became ready');
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    expect(await waitFor(tester, find.text('Export PDF')), isTrue);
    await tester.tap(find.text('Export PDF'));
    final backHome = await waitFor(
      tester,
      find.byType(FloatingActionButton),
      timeout: const Duration(seconds: 30),
    );
    final scans = await repository.all();
    // ignore: avoid_print
    print('PDFFLOW back=$backHome scans=${scans.length} '
        'pdfs=${scans.where((s) => s.isPdf).length}');
    expect(backHome, isTrue, reason: 'PDF export did not return to My Scans');
    expect(
      scans.any((entry) => entry.isPdf),
      isTrue,
      reason: 'PDF export was not recorded in history',
    );
  });
}
