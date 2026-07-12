import '../entities/scan_data.dart';

enum ScannerAccessState { ready, permissionDenied, unsupported, unavailable }

abstract interface class BarcodeScannerCapability {
  Stream<ScanData> get scans;
  ScannerAccessState get accessState;
  Stream<ScannerAccessState> get accessStates;
  Future<void> start();
  Future<void> stop();
  Future<void> setTorch(bool enabled);
  Future<void> setZoom(double value);
  Future<void> focus(double x, double y);
  Future<void> dispose();
}
