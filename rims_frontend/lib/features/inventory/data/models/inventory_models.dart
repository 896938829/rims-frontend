import '../../domain/entities/inventory_item.dart';

final class InventoryItemModel {
  const InventoryItemModel({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.availableQuantity,
    required this.stockQuantity,
    required this.statusLabel,
    required this.imageUrl,
  });

  factory InventoryItemModel.fromJson(Map<dynamic, dynamic> json) {
    final product = _readMap(json, 'product');
    final productName =
        _readString(json, const ['productName', 'name', 'title']) ??
        _readString(product, const ['name', 'productName', 'title']) ??
        '';
    final sku =
        _readString(json, const ['sku', 'skuCode', 'productCode', 'barcode']) ??
        _readString(product, const ['sku', 'skuCode', 'code', 'barcode']) ??
        '';
    final availableQuantity =
        _readInt(json, const [
          'availableQuantity',
          'availableQty',
          'available',
          'quantity',
        ]) ??
        0;
    final stockQuantity =
        _readInt(json, const [
          'stockQuantity',
          'stockQty',
          'stock',
          'totalQuantity',
          'quantity',
        ]) ??
        availableQuantity;
    final rawStatus =
        _readString(json, const ['statusLabel', 'statusName', 'stateName']) ??
        _readString(product, const ['statusLabel', 'statusName']) ??
        '';

    return InventoryItemModel(
      id: _readInt(json, const ['id', 'inventoryId']) ?? 0,
      productId:
          _readInt(json, const ['productId', 'goodsId']) ??
          _readInt(product, const ['id', 'productId']) ??
          0,
      productName: productName,
      sku: sku,
      availableQuantity: availableQuantity,
      stockQuantity: stockQuantity,
      statusLabel: rawStatus.isNotEmpty
          ? rawStatus
          : _statusLabel(
              _readString(json, const ['status', 'state', 'inventoryStatus']),
              availableQuantity,
              stockQuantity,
            ),
      imageUrl:
          _readString(json, const ['imageUrl', 'image', 'thumbnailUrl']) ??
          _readString(product, const ['imageUrl', 'image', 'thumbnailUrl']) ??
          '',
    );
  }

  final int id;
  final int productId;
  final String productName;
  final String sku;
  final int availableQuantity;
  final int stockQuantity;
  final String statusLabel;
  final String imageUrl;

  InventoryItem toEntity() {
    return InventoryItem(
      id: id,
      productId: productId,
      productName: productName,
      sku: sku,
      availableQuantity: availableQuantity,
      stockQuantity: stockQuantity,
      statusLabel: statusLabel,
      imageUrl: imageUrl,
    );
  }
}

Map<dynamic, dynamic> _readMap(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  return value is Map ? Map<dynamic, dynamic>.from(value) : const {};
}

int? _readInt(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value) ?? double.tryParse(value)?.round();
    }
  }

  return null;
}

String? _readString(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toString();
    }
  }

  return null;
}

String _statusLabel(
  String? rawStatus,
  int availableQuantity,
  int stockQuantity,
) {
  final normalized = rawStatus?.toLowerCase() ?? '';
  if (normalized.contains('low') ||
      normalized.contains('warning') ||
      normalized == '2') {
    return '低库存';
  }
  if (normalized.contains('non') ||
      normalized.contains('exception') ||
      normalized == '3') {
    return '非标';
  }
  if (stockQuantity > 0 && availableQuantity <= 5) {
    return '低库存';
  }

  return '标准';
}
