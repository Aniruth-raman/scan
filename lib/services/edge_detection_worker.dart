import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'edge_detector.dart';

/// A persistent isolate that runs [EdgeDetector] off the UI thread.
///
/// Spawning an isolate per camera frame is both expensive and unsafe: a closure
/// created inside a widget would capture the widget state (and the camera
/// controller it holds), which cannot be sent to another isolate. A single
/// long-lived worker receives plain data and returns a [DocumentQuad], so the
/// UI isolate only pays for the luminance copy.
class EdgeDetectionWorker {
  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _commands;
  final Map<int, Completer<DocumentQuad?>> _pending = {};
  int _nextId = 1;

  bool get isReady => _commands != null;

  Future<void> start() async {
    if (_commands != null) return;
    final receive = ReceivePort();
    _receive = receive;
    final ready = Completer<SendPort>();
    receive.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.length == 2) {
        final id = message[0] as int;
        final quad = message[1] as DocumentQuad?;
        final completer = _pending.remove(id);
        if (completer != null && !completer.isCompleted) {
          completer.complete(quad);
        }
      }
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      receive.sendPort,
      debugName: 'edge-detection',
    );
    _commands = await ready.future;
  }

  /// Detects a document quad in a camera luminance (Y) plane.
  ///
  /// Returns null when no worker is running or no document is visible.
  Future<DocumentQuad?> detect({
    required Uint8List luminance,
    required int width,
    required int height,
    required int bytesPerRow,
    required int rotationDegrees,
    bool mirrored = false,
  }) async {
    final commands = _commands;
    if (commands == null) return null;
    final id = _nextId++;
    final completer = Completer<DocumentQuad?>();
    _pending[id] = completer;
    commands.send([
      id,
      TransferableTypedData.fromList([luminance]),
      width,
      height,
      bytesPerRow,
      rotationDegrees,
      mirrored,
    ]);
    return completer.future;
  }

  void dispose() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
  }
}

void _workerMain(SendPort out) {
  final commands = ReceivePort();
  out.send(commands.sendPort);
  commands.listen((message) {
    if (message is! List || message.length != 7) return;
    final id = message[0] as int;
    final data = (message[1] as TransferableTypedData)
        .materialize()
        .asUint8List();
    DocumentQuad? quad;
    try {
      quad = EdgeDetector.detectInPlane(
        data,
        width: message[2] as int,
        height: message[3] as int,
        bytesPerRow: message[4] as int,
        rotationDegrees: message[5] as int,
        mirrored: message[6] as bool,
      );
    } catch (_) {
      quad = null;
    }
    out.send([id, quad]);
  });
}
