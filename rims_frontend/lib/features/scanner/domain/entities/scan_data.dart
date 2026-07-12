import '../../../inventory/domain/entities/inventory_item.dart';

enum ScanMode { single, continuous, batch, quantity }

enum ScanCodeFormat { code128, code39, ean13, ean8, qrCode, unknown }

final class ScanData {
  const ScanData({
    required this.value,
    required this.format,
    required this.capturedAt,
  });

  final String value;
  final ScanCodeFormat format;
  final DateTime capturedAt;

  bool get isSupported => format != ScanCodeFormat.unknown;
}

final class ScanLine {
  const ScanLine({
    required this.item,
    required this.quantity,
    this.isStale = false,
  });

  final InventoryItem item;
  final int quantity;
  final bool isStale;

  ScanLine copyWith({int? quantity, bool? isStale}) {
    return ScanLine(
      item: item,
      quantity: quantity ?? this.quantity,
      isStale: isStale ?? this.isStale,
    );
  }
}

enum ScanIssue {
  empty,
  unsupported,
  unknown,
  disabled,
  wrongWarehouse,
  wrongBatch,
  permissionDenied,
  network,
  maxLines,
}
