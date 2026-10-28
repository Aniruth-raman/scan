import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'document_detector.dart';

/// A long-lived isolate that owns the page-segmentation interpreter.
///
/// The model has to be parsed and its tensors allocated once, not per frame, and
/// inference must not block the UI isolate. Assets cannot be loaded off the root
/// isolate, so [start] reads the model bytes here and hands them over; the
/// isolate builds the interpreter and reports when it is ready.
///
/// A single instance is shared by the capture stage (live overlay) and the crop
/// stage (one-shot detection), so the model is loaded once per process.
class DocumentDetectionWorker {
  DocumentDetectionWorker._();

  static final DocumentDetectionWorker instance = DocumentDetectionWorker._();

  SendPort? _commands;
  final Map<int, Completer<DocumentQuad?>> _pending = {};
  int _nextId = 1;
  Future<void>? _starting;

  bool get isReady => _commands != null;

  /// Loads the model in the worker. Safe to call repeatedly.
  Future<void> start() => _starting ??= _spawn();

  Future<void> _spawn() async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    final loaded = Completer<bool>();

    receive.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! List || message.length != 2) return;
      final id = message[0] as int;
      if (id == 0) {
        if (!loaded.isCompleted) loaded.complete(message[1] == true);
        return;
      }
      final completer = _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message[1] as DocumentQuad?);
      }
    });

    await Isolate.spawn(
      _workerMain,
      receive.sendPort,
      debugName: 'document-detection',
    );
    final commands = await ready.future;
    _commands = commands;

    final model = await rootBundle.load('assets/models/document_mask.tflite');
    commands.send(
      TransferableTypedData.fromList([
        model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
      ]),
    );
    if (!await loaded.future) {
      // No detector: callers fall back to the full frame.
      _commands = null;
    }
  }

  /// Detects a quad in a prepared model input, built by [prepareYuvInput] or
  /// [prepareRgbaInput]. The two sizes are the frame's display-oriented size,
  /// which the returned corners are expressed in.
  Future<DocumentQuad?> detectPrepared(
    Float32List input, {
    required int displayWidth,
    required int displayHeight,
  }) {
    if (!isReady) return Future<DocumentQuad?>.value();
    return _send(0, input, [displayWidth, displayHeight]);
  }

  /// Detects a quad in a display-oriented RGBA buffer from the native analyser.
  Future<DocumentQuad?> detectRgba(
    Uint8List rgba, {
    required int width,
    required int height,
  }) {
    if (!isReady) return Future<DocumentQuad?>.value();
    return _send(1, rgba, [width, height]);
  }

  Future<DocumentQuad?> _send(int kind, TypedData data, List<int> geometry) {
    final commands = _commands;
    if (commands == null) return Future<DocumentQuad?>.value();
    final id = _nextId++;
    final completer = Completer<DocumentQuad?>();
    _pending[id] = completer;
    commands.send([
      id,
      kind,
      TransferableTypedData.fromList([data]),
      ...geometry,
    ]);
    return completer.future;
  }
}

Future<void> _workerMain(SendPort out) async {
  final commands = ReceivePort();
  out.send(commands.sendPort);
  DocumentDetector? detector;

  commands.listen((message) {
    if (message is TransferableTypedData) {
      // First message: the model bytes.
      try {
        detector = DocumentDetector.load(message.materialize().asUint8List());
      } catch (error) {
        detector = null;
        debugPrint('document model failed to load: $error');
        out.send([0, false]);
        return;
      }
      out.send([0, true]);
      return;
    }
    if (message is! List || message.length != 5) return;
    final id = message[0] as int;
    final data = message[2] as TransferableTypedData;
    DocumentQuad? quad;
    final active = detector;
    if (active != null) {
      try {
        quad = message[1] == 0
            ? active.detectPrepared(
                data.materialize().asFloat32List(),
                displayWidth: message[3] as int,
                displayHeight: message[4] as int,
              )
            : active.detectFromRgba(
                data.materialize().asUint8List(),
                width: message[3] as int,
                height: message[4] as int,
              );
      } catch (_) {
        quad = null;
      }
    }
    out.send([id, quad]);
  });
}
