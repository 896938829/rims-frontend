import 'dart:async';
import 'dart:ui';

import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/entities/scan_data.dart';
import '../domain/services/barcode_scanner_capability.dart';

final class MobileScannerCapability implements BarcodeScannerCapability {
  MobileScannerCapability({
    MobileScannerController? controller,
    DateTime Function()? now,
  }) : controller =
           controller ??
           MobileScannerController(
             autoStart: false,
             detectionSpeed: DetectionSpeed.unrestricted,
           ),
       _now = now ?? DateTime.now {
    _barcodeSubscription = MobileScannerPlatform.instance.barcodesStream.listen(
      _forwardCapture,
      onError: _scanController.addError,
    );
  }

  final MobileScannerController controller;
  final DateTime Function() _now;
  final StreamController<ScanData> _scanController =
      StreamController<ScanData>.broadcast();
  final StreamController<ScannerAccessState> _accessController =
      StreamController<ScannerAccessState>.broadcast();
  late final StreamSubscription<BarcodeCapture?> _barcodeSubscription;

  Future<void> _operations = Future<void>.value();
  Future<void>? _disposeFuture;
  ScannerAccessState _accessState = ScannerAccessState.unavailable;
  bool _disposeRequested = false;
  bool _disposed = false;

  @override
  Stream<ScanData> get scans => _scanController.stream;

  @override
  ScannerAccessState get accessState => _accessState;

  @override
  Stream<ScannerAccessState> get accessStates => _accessController.stream;

  @override
  Future<void> start() {
    if (_disposeRequested) return _operations;
    return _serialize(() async {
      if (_disposed) return;
      try {
        await controller.start();
        _setAccessState(_accessStateFrom(controller.value));
      } on MobileScannerException catch (error) {
        _setAccessState(_accessStateFromError(error.errorCode));
      } on Object {
        _setAccessState(ScannerAccessState.unavailable);
      }
    });
  }

  @override
  Future<void> stop() {
    if (_disposeRequested) return _operations;
    return _serialize(() async {
      if (_disposed) return;
      try {
        await controller.stop();
      } on Object {
        // A late platform lifecycle callback must not escape to the page.
      }
    });
  }

  @override
  Future<void> setTorch(bool enabled) => _control(() async {
    final torchState = controller.value.torchState;
    if (torchState == TorchState.unavailable) return;
    final isEnabled = torchState == TorchState.on;
    if (isEnabled != enabled) await controller.toggleTorch();
  });

  @override
  Future<void> setZoom(double value) =>
      _control(() => controller.setZoomScale(value.clamp(0.0, 1.0).toDouble()));

  @override
  Future<void> focus(double x, double y) => _control(
    () => controller.setFocusPoint(
      Offset(x.clamp(0.0, 1.0).toDouble(), y.clamp(0.0, 1.0).toDouble()),
    ),
  );

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposeRequested = true;
    final future = _serialize(() async {
      if (_disposed) return;
      _disposed = true;
      await _barcodeSubscription.cancel();
      await _scanController.close();
      await _accessController.close();
      await controller.dispose();
    });
    _disposeFuture = future;
    return future;
  }

  Future<void> _control(Future<void> Function() operation) {
    if (_disposeRequested) return _operations;
    return _serialize(() async {
      if (_disposed || !controller.value.isRunning) return;
      try {
        await operation();
      } on Object {
        // Hardware controls are optional and must remain safe during teardown.
      }
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object _) {});
    return result;
  }

  void _forwardCapture(BarcodeCapture? capture) {
    if (_disposed ||
        _accessState != ScannerAccessState.ready ||
        _scanController.isClosed ||
        capture == null) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      _scanController.add(
        ScanData(
          value: value,
          format: _mapFormat(barcode.format),
          capturedAt: _now(),
        ),
      );
    }
  }

  void _setAccessState(ScannerAccessState value) {
    if (_disposed || value == _accessState) return;
    _accessState = value;
    _accessController.add(value);
  }

  static ScannerAccessState _accessStateFrom(MobileScannerState state) {
    final error = state.error;
    if (error != null) return _accessStateFromError(error.errorCode);
    if (state.availableCameras == 0) return ScannerAccessState.unsupported;
    if (state.isRunning) return ScannerAccessState.ready;
    return ScannerAccessState.unavailable;
  }

  static ScannerAccessState _accessStateFromError(
    MobileScannerErrorCode error,
  ) => switch (error) {
    MobileScannerErrorCode.permissionDenied =>
      ScannerAccessState.permissionDenied,
    MobileScannerErrorCode.unsupported => ScannerAccessState.unsupported,
    _ => ScannerAccessState.unavailable,
  };

  static ScanCodeFormat _mapFormat(BarcodeFormat format) => switch (format) {
    BarcodeFormat.code128 => ScanCodeFormat.code128,
    BarcodeFormat.code39 => ScanCodeFormat.code39,
    BarcodeFormat.ean13 => ScanCodeFormat.ean13,
    BarcodeFormat.ean8 => ScanCodeFormat.ean8,
    BarcodeFormat.qrCode => ScanCodeFormat.qrCode,
    _ => ScanCodeFormat.unknown,
  };
}
