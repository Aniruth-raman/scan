import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device probe: reports exactly how the camera stack behaves on the
/// connected handset, one step at a time, so a runtime failure is attributable.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('camera stack probe', (tester) async {
    List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
      // ignore: avoid_print
      print('PROBE availableCameras -> ${cameras.length}');
      for (final c in cameras) {
        // ignore: avoid_print
        print('PROBE camera: ${c.name} ${c.lensDirection} '
            'sensorOrientation=${c.sensorOrientation}');
      }
    } catch (e, s) {
      // ignore: avoid_print
      print('PROBE availableCameras FAILED: $e\n$s');
      return;
    }

    if (cameras.isEmpty) {
      // ignore: avoid_print
      print('PROBE no cameras reported by plugin');
      return;
    }

    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    Future<void> probe(String label, ImageFormatGroup? group) async {
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: group,
      );
      try {
        await controller.initialize();
        final v = controller.value;
        // ignore: avoid_print
        print('PROBE[$label] initialize OK preview=${v.previewSize} '
            'aspect=${v.aspectRatio}');
        try {
          await controller.setFlashMode(FlashMode.off);
          // ignore: avoid_print
          print('PROBE[$label] setFlashMode OK');
        } catch (e) {
          // ignore: avoid_print
          print('PROBE[$label] setFlashMode FAILED: $e');
        }
        try {
          await controller.startImageStream((image) {});
          // ignore: avoid_print
          print('PROBE[$label] startImageStream OK');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          await controller.stopImageStream();
          // ignore: avoid_print
          print('PROBE[$label] stopImageStream OK');
        } catch (e, s) {
          // ignore: avoid_print
          print('PROBE[$label] startImageStream FAILED: $e\n$s');
        }
        try {
          final file = await controller.takePicture();
          // ignore: avoid_print
          print('PROBE[$label] takePicture OK ${file.path}');
        } catch (e) {
          // ignore: avoid_print
          print('PROBE[$label] takePicture FAILED: $e');
        }
      } catch (e, s) {
        // ignore: avoid_print
        print('PROBE[$label] initialize FAILED: $e\n$s');
      } finally {
        try {
          await controller.dispose();
        } catch (_) {}
      }
    }

    await probe('jpeg', ImageFormatGroup.jpeg);
    await probe('yuv420', ImageFormatGroup.yuv420);
    await probe('default', null);
  });
}
