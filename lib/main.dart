import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/scan_repository.dart';
import 'design/scan_theme.dart';
import 'screens/history_screen.dart';
import 'services/scan_exporter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Scan is portrait-only on phones: the capture stage, crop stage and editor
  // are all laid out for a 384 x 832 dp viewport. Locking here keeps the
  // measured geometry valid and stops the camera preview from rotating out
  // from under the chrome.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final repository = SqfliteScanRepository();
  final documents = await getApplicationDocumentsDirectory();
  final storage = Directory(p.join(documents.path, 'scans'));
  await storage.create(recursive: true);

  runApp(
    ScanApp(
      repository: repository,
      exporter: ScanExporter(repository: repository, storageDirectory: storage),
    ),
  );
}

class ScanApp extends StatelessWidget {
  const ScanApp({
    super.key,
    required this.repository,
    required this.exporter,
  });

  final ScanRepository repository;
  final ScanExporter exporter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scan',
      debugShowCheckedModeBanner: false,
      // One theme. Scan switches chrome by stage (black camera, white editor),
      // never by system brightness, so there is no dark theme to select.
      theme: ScanTheme.editor(),
      themeMode: ThemeMode.light,
      home: HistoryScreen(repository: repository, exporter: exporter),
    );
  }
}
