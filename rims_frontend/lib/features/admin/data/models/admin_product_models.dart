import '../../domain/entities/admin_product.dart';

final class AdminProductModel {
  const AdminProductModel({
    required this.id,
    required this.code,
    required this.name,
    required this.unit,
    required this.category,
    required this.spec,
    required this.barcode,
    required this.retailPrice,
    required this.costPrice,
    required this.imageUrl,
    required this.status,
  });

  factory AdminProductModel.fromJson(Map<dynamic, dynamic> json) {
    return AdminProductModel(
      id: _readInt(json, const ['id', 'productId']) ?? 0,
      code: _readString(json, const ['code', 'productCode', 'sku']) ?? '',
      name: _readString(json, const ['name', 'productName']) ?? '',
      unit: _readString(json, const ['unit', 'unitName']) ?? '',
      category: _readString(json, const ['category', 'categoryName']) ?? '',
      spec: _readString(json, const ['spec', 'specification']) ?? '',
      barcode: _readString(json, const ['barcode', 'barCode']) ?? '',
      retailPrice: _readDouble(json, const ['retailPrice', 'salePrice']),
      costPrice: _readDouble(json, const ['costPrice']),
      imageUrl: _readString(json, const ['imageUrl', 'image']) ?? '',
      status: _readInt(json, const ['status', 'state']) ?? 0,
    );
  }

  final int id;
  final String code;
  final String name;
  final String unit;
  final String category;
  final String spec;
  final String barcode;
  final double? retailPrice;
  final double? costPrice;
  final String imageUrl;
  final int status;

  AdminProduct toEntity() {
    return AdminProduct(
      id: id,
      code: code,
      name: name,
      unit: unit,
      category: category,
      spec: spec,
      barcode: barcode,
      retailPrice: retailPrice,
      costPrice: costPrice,
      imageUrl: imageUrl,
      status: status,
    );
  }
}

Map<String, Object> createAdminProductRequestToJson(
  CreateAdminProductRequest request,
) {
  return {
    'code': request.code.trim(),
    'name': request.name.trim(),
    'unit': request.unit.trim(),
    if (request.category.trim().isNotEmpty) 'category': request.category.trim(),
    if (request.spec.trim().isNotEmpty) 'spec': request.spec.trim(),
    if (request.barcode.trim().isNotEmpty) 'barcode': request.barcode.trim(),
    if (request.retailPrice != null) 'retailPrice': request.retailPrice!,
    if (request.costPrice != null) 'costPrice': request.costPrice!,
    if (request.imageUrl.trim().isNotEmpty) 'imageUrl': request.imageUrl.trim(),
    'status': request.status,
  };
}

Map<String, Object> updateAdminProductRequestToJson(
  UpdateAdminProductRequest request,
) {
  return {
    'code': request.code.trim(),
    'name': request.name.trim(),
    'unit': request.unit.trim(),
    if (request.category.trim().isNotEmpty) 'category': request.category.trim(),
    if (request.spec.trim().isNotEmpty) 'spec': request.spec.trim(),
    if (request.barcode.trim().isNotEmpty) 'barcode': request.barcode.trim(),
    if (request.retailPrice != null) 'retailPrice': request.retailPrice!,
    if (request.costPrice != null) 'costPrice': request.costPrice!,
    if (request.imageUrl.trim().isNotEmpty) 'imageUrl': request.imageUrl.trim(),
    if (request.status != null) 'status': request.status!,
  };
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
