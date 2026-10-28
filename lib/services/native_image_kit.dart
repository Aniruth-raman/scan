import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tone presets, mirroring Lens's `ProcessMode.Scan` palette.
///
/// The labels are the original's strings (`lenshvc_image_filter_scan_*`), which
/// is why `document` reads "Lighten" and `sauvolaColor` reads "Document": in the
/// shipped app those are the two different modes, not a typo.
///
/// [id] is part of the MethodChannel contract and must match the `FILTER_*`
/// constants in `ScanImageKit.kt`.
enum ScanFilter {
  none(0, 'None'),
  document(1, 'Lighten'),
  whiteboard(2, 'Whiteboard'),
  blackAndWhite(3, 'B&W'),
  grayscale(4, 'Grayscale'),
  sauvolaColor(5, 'Document'),
  sbcAdjust(6, 'Brighten');

  const ScanFilter(this.id, this.label);

  final int id;
  final String label;
}

/// PDF size choice, mirroring Lens's `PdfQuality{High, Medium, Low}`.
///
/// High embeds the saved page JPEG unchanged, so choosing it costs no extra
/// generation; Medium and Low re-encode the page smaller.
enum PdfQuality { high, medium, low }

/// The pipeline's settings, in one object.
///
/// Mirrors what Lens keeps per processed page: `ProcessMode`, the JPEG quality
/// from `MediaCompression`, the `ImageDPI` written to the file, and the
/// `PdfQuality` used at export.
@immutable
class ScanProfile {
  const ScanProfile({
    this.filter = ScanFilter.none,
    this.jpegQuality = lensQuality,
    this.dpi = lensDpi,
    this.pdfQuality = PdfQuality.high,
  });

  /// Lens's default: `MediaCompression.low.getCompressionSize() == 0.75`, used
  /// as `(int) (compression * 100)` when the page is written.
  static const int lensQuality = 75;

  /// Lens's default is "native" (`ImageDPI.high == -1`). A PDF still needs a
  /// number, so 300 is used: 2480 px then maps to A4 width exactly.
  static const int lensDpi = 300;

  final ScanFilter filter;
  final int jpegQuality;
  final int dpi;
  final PdfQuality pdfQuality;
}

/// One file sitting in the app's shared folders — captured here, or dropped in
/// from somewhere else (USB, another app, a download).
@immutable
class SharedMedia {
  const SharedMedia({
    required this.uri,
    required this.name,
    required this.mime,
    required this.modified,
    required this.size,
    this.thumb,
  });

  final String uri;

  /// File name including its extension.
  final String name;
  final String mime;
  final DateTime modified;
  final int size;

  /// 240 px JPEG preview, images only.
  final Uint8List? thumb;

  bool get isPdf => mime == 'application/pdf';

  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// Optionally-published result: where the shared copy landed.
typedef PublishedFile = ({String uri, String name, String location});

/// Thin bridge to [ScanImageKit] on the Android side.
///
/// Decoding, EXIF orientation, perspective rectification, tone mapping, JPEG
/// encoding and PDF assembly are all platform work. Dart never holds a
/// full-resolution pixel buffer, which is what keeps previews crisp and the
/// isolate heap small.
abstract final class NativeImageKit {
  static const MethodChannel _channel = MethodChannel('scan/image');

  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  static void _requireAndroid() {
    if (!isSupported) {
      throw UnsupportedError('NativeImageKit requires Android');
    }
  }

  /// Bakes the review stage's edit into a page: a quarter-turn rotation,
  /// decoded and encoded once.
  ///
  /// The turn is held as state while editing, so this runs once per page at save
  /// time instead of re-encoding on every tap.
  static Future<Uint8List> transform(
    Uint8List bytes, {
    int quarterTurns = 0,
    int quality = ScanProfile.lensQuality,
  }) async {
    _requireAndroid();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'transform',
      {'bytes': bytes, 'quarterTurns': quarterTurns, 'quality': quality},
    );
    if (result == null) throw StateError('transform returned no result');
    return result['bytes'] as Uint8List;
  }

  /// Decodes at a reduced sample size, so a 12 MP page never reaches the heap.
  static Future<Uint8List> thumbnail(
    Uint8List bytes, {
    int maxEdge = 320,
    int quality = 80,
  }) async {
    _requireAndroid();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'thumbnail',
      {'bytes': bytes, 'maxEdge': maxEdge, 'quality': quality},
    );
    if (result == null) throw StateError('thumbnail returned no result');
    return result['bytes'] as Uint8List;
  }

  /// Publishes a finished page into the gallery album and returns the content
  /// URI, which the scan list keeps so deletes reach exactly this file.
  static Future<PublishedFile> publishImage(
    Uint8List bytes, {
    required String name,
    String folder = 'Scan',
  }) async {
    _requireAndroid();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'publishImage',
      {'bytes': bytes, 'name': name, 'folder': folder},
    );
    if (result == null) throw StateError('publishImage returned no result');
    return (
      uri: result['uri'] as String,
      name: result['name'] as String,
      location: result['location'] as String,
    );
  }

  /// Lists both shared folders: the gallery album and the Downloads folder.
  static Future<List<SharedMedia>> listShared() async {
    _requireAndroid();
    final result = await _channel.invokeMethod<List<Object?>>('listShared');
    if (result == null) return const <SharedMedia>[];
    return [
      for (final item in result)
        if (item is Map)
          SharedMedia(
            uri: item['uri'] as String,
            name: item['name'] as String,
            mime: item['mime'] as String,
            modified: DateTime.fromMillisecondsSinceEpoch(
              item['modified'] as int,
            ),
            size: item['size'] as int,
            thumb: item['thumb'] as Uint8List?,
          ),
    ];
  }

  /// Removes published files by URI and returns how many went.
  static Future<int> deleteShared(List<String> uris) async {
    if (uris.isEmpty) return 0;
    _requireAndroid();
    return await _channel.invokeMethod<int>('deleteShared', {'uris': uris}) ??
        0;
  }

  /// Writes the page's DPI into its EXIF block, without re-encoding it.
  ///
  /// Lens stamps the processed page the same way, which is what lets a later
  /// reader know the page's physical size.
  static Future<void> setJpegDpi(
    String path, {
    int dpi = ScanProfile.lensDpi,
  }) async {
    _requireAndroid();
    if (dpi <= 0) return;
    await _channel.invokeMethod<bool>('setJpegDpi', {'path': path, 'dpi': dpi});
  }

  /// Publishes a full-bleed multi-page PDF into shared Downloads and returns
  /// where it landed: the collection (`Download/Scan`) and the file name.
  ///
  /// [recordPath] additionally receives the same bytes, so the app keeps its own
  /// copy to list and open; the shared copy is the export.
  static Future<({String uri, String name, String location})> writePdf({
    required List<Uint8List> pages,
    required String name,
    required String recordPath,
    String folder = 'Scan',
    int dpi = ScanProfile.lensDpi,
    PdfQuality pdfQuality = PdfQuality.high,
  }) async {
    _requireAndroid();
    final result = await _channel.invokeMapMethod<String, dynamic>('writePdf', {
      'pages': pages,
      'name': name,
      'folder': folder,
      'recordPath': recordPath,
      'dpi': dpi,
      'pdfQuality': pdfQuality.index,
    });
    if (result == null) throw StateError('writePdf returned no result');
    return (
      uri: result['uri'] as String,
      name: result['name'] as String,
      location: result['location'] as String,
    );
  }

  /// Opens a saved scan in whatever viewer the device provides.
  static Future<void> openFile({
    required String path,
    required String mimeType,
  }) async {
    _requireAndroid();
    await _channel.invokeMethod<void>('openFile', {
      'path': path,
      'mime': mimeType,
    });
  }
}
