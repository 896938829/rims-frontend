import 'dart:async';

import '../domain/entities/scan_data.dart';
import '../domain/services/barcode_scanner_capability.dart';

final class FieldOperationsTestConfig {
  const FieldOperationsTestConfig({
    required this.enabled,
    required this.barcode,
    required this.pickedFile,
  });

  static const current = FieldOperationsTestConfig(
    enabled: bool.fromEnvironment('RIMS_E2E_FIELD_OPERATIONS'),
    barcode: String.fromEnvironment('RIMS_E2E_BARCODE'),
    pickedFile: String.fromEnvironment('RIMS_E2E_PICKED_FILE'),
  );

  final bool enabled;
  final String barcode;
  final String pickedFile;
}

final class FieldOperationsScanner implements BarcodeScannerCapability {
  FieldOperationsScanner({required this.barcode, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final String barcode;
  final DateTime Function() _now;
  final StreamController<ScanData> _scans = StreamController.broadcast();
  final StreamController<ScannerAccessState> _accessStates =
      StreamController.broadcast();
  ScannerAccessState _accessState = ScannerAccessState.unavailable;
  int _starts = 0;
  bool _emitted = false;
  bool _disposed = false;

  @override
  Stream<ScanData> get scans => _scans.stream;

  @override
  ScannerAccessState get accessState => _accessState;

  @override
  Stream<ScannerAccessState> get accessStates => _accessStates.stream;

  @override
  Future<void> start() async {
    if (_disposed) return;
    _starts += 1;
    if (_starts == 1) {
      _setAccess(ScannerAccessState.permissionDenied);
      return;
    }
    _setAccess(ScannerAccessState.ready);
    if (!_emitted && barcode.trim().isNotEmpty) {
      _emitted = true;
      scheduleMicrotask(() {
        if (!_disposed) {
          _scans.add(
            ScanData(
              value: barcode.trim(),
              format: ScanCodeFormat.code128,
              capturedAt: _now(),
            ),
          );
        }
      });
    }
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> setTorch(bool enabled) async {}

  @override
  Future<void> setZoom(double value) async {}

  @override
  Future<void> focus(double x, double y) async {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _scans.close();
    await _accessStates.close();
  }

  void _setAccess(ScannerAccessState value) {
    _accessState = value;
    _accessStates.add(value);
  }
}
