import '../entities/scan_data.dart';

abstract interface class BarcodeScannerCapability {
  Stream<ScanData> get scans;
  Future<void> start();
  Future<void> stop();
  Future<void> setTorch(bool enabled);
  Future<void> setZoom(double value);
  Future<void> focus(double x, double y);
  Future<void> dispose();
}
