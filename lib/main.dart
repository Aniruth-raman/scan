import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/scan_repository.dart';
import 'design/lens_theme.dart';
import 'screens/history_screen.dart';
import 'services/scan_exporter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final repository = SqfliteScanRepository();
  final documents = await getApplicationDocumentsDirectory();
  final storage = Directory(p.join(documents.path, 'scans'));
  await storage.create(recursive: true);

  runApp(
    LensLiteApp(
      repository: repository,
      exporter: ScanExporter(
        repository: repository,
        storageDirectory: storage,
      ),
    ),
  );
}

class LensLiteApp extends StatelessWidget {
  const LensLiteApp({
    super.key,
    required this.repository,
    required this.exporter,
  });

  final ScanRepository repository;
  final ScanExporter exporter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lens Lite',
      debugShowCheckedModeBanner: false,
      // One theme. Lens switches chrome by stage (black camera, white editor),
      // never by system brightness, so there is no dark theme to select.
      theme: LensTheme.editor(),
      themeMode: ThemeMode.light,
      home: HistoryScreen(repository: repository, exporter: exporter),
    );
  }
}