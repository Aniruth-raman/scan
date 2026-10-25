import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/scan_repository.dart';
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

  ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1565C0),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      splashFactory: InkSparkle.splashFactory,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        scrolledUnderElevation: 2,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lens Lite',
      debugShowCheckedModeBanner: false,
      theme: _base(Brightness.light),
      darkTheme: _base(Brightness.dark),
      themeMode: ThemeMode.system,
      home: HistoryScreen(repository: repository, exporter: exporter),
    );
  }
}