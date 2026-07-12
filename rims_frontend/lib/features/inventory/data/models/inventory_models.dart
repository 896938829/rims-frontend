import '../../domain/entities/inventory_item.dart';
import '../../domain/entities/non_standard_inventory_item.dart';

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
    this.alertThreshold,
    this.status,
    this.retailPrice,
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
    final stockQuantity =
        _readInt(json, const [
          'stockQuantity',
          'stockQty',
          'stock',
          'totalQuantity',
          'quantity',
        ]) ??
        0;
    final lockedQuantity =
        _readInt(json, const ['lockedQuantity', 'lockedQty', 'locked']) ?? 0;
    final availableQuantity =
        _readInt(json, const [
          'availableQuantity',
          'availableQty',
          'available',
        ]) ??
        (stockQuantity - lockedQuantity).clamp(0, stockQuantity).toInt();
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
      retailPrice:
          _readDouble(json, const [
            'retailPrice',
            'salePrice',
            'sellingPrice',
            'price',
          ]) ??
          _readDouble(product, const [
            'retailPrice',
            'salePrice',
            'sellingPrice',
            'price',
          ]),
      alertThreshold: _readInt(json, const [
        'alertThreshold',
        'threshold',
        'warningThreshold',
      ]),
      status: _readInt(json, const ['status', 'state', 'inventoryStatus']),
    );
  }

  factory InventoryItemModel.fromProductJson(Map<dynamic, dynamic> json) {
    return InventoryItemModel(
      id: 0,
      productId: _readInt(json, const ['id', 'productId']) ?? 0,
      productName:
          _readString(json, const ['productName', 'name', 'title']) ?? '',
      sku: _readString(json, const ['sku', 'skuCode', 'code', 'barcode']) ?? '',
      availableQuantity: 0,
      stockQuantity: 0,
      statusLabel: '标准',
      imageUrl: _readString(json, const ['imageUrl', 'image']) ?? '',
      retailPrice: _readDouble(json, const [
        'retailPrice',
        'salePrice',
        'sellingPrice',
        'price',
      ]),
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
  final int? alertThreshold;
  final int? status;
  final double? retailPrice;

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
      alertThreshold: alertThreshold,
      status: status,
      retailPrice: retailPrice,
    );
  }
}

final class NonStandardInventoryItemModel {
  const NonStandardInventoryItemModel({
    required this.id,
    required this.tempLabel,
    required this.description,
    required this.unit,
    required this.quantity,
    required this.convertedQuantity,
    required this.remainingQuantity,
    required this.status,
  });

  factory NonStandardInventoryItemModel.fromJson(Map<dynamic, dynamic> json) {
    final quantity = _readInt(json, const ['quantity', 'qty']) ?? 0;
    final convertedQuantity =
        _readInt(json, const ['convertedQty', 'convertedQuantity']) ?? 0;

    return NonStandardInventoryItemModel(
      id: _readInt(json, const ['id', 'nonStdInvId']) ?? 0,
      tempLabel: _readString(json, const ['tempLabel', 'label']) ?? '',
      description: _readString(json, const ['description', 'desc']) ?? '',
      unit: _readString(json, const ['unit', 'unitName']) ?? '',
      quantity: quantity,
      convertedQuantity: convertedQuantity,
      remainingQuantity:
          _readInt(json, const ['remainingQty', 'remainingQuantity']) ??
          (quantity - convertedQuantity),
      status: _readInt(json, const ['status', 'state']) ?? 0,
    );
  }

  final int id;
  final String tempLabel;
  final String description;
  final String unit;
  final int quantity;
  final int convertedQuantity;
  final int remainingQuantity;
  final int status;

  NonStandardInventoryItem toEntity() {
    return NonStandardInventoryItem(
      id: id,
      tempLabel: tempLabel,
      description: description,
      unit: unit,
      quantity: quantity,
      convertedQuantity: convertedQuantity,
      remainingQuantity: remainingQuantity,
      status: status,
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

double? _readDouble(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim());
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
