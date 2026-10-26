import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lens_lite/services/native_image_kit.dart';

/// Diagnostic: what does the folder indexer actually see on this device?
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shared folder probe', (tester) async {
    final media = await NativeImageKit.listShared();
    // ignore: avoid_print
    print('SHARED count=${media.length}');
    for (final item in media) {
      // ignore: avoid_print
      print(
        'SHARED ${item.uri} name=${item.name} mime=${item.mime} '
        'thumb=${item.thumb?.length ?? 0}',
      );
    }
  });
}
