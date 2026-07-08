final class AdminProduct {
  const AdminProduct({
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

  bool get isActive => status == 1;
}

final class CreateAdminProductRequest {
  const CreateAdminProductRequest({
    required this.code,
    required this.name,
    required this.unit,
    this.category = '',
    this.spec = '',
    this.barcode = '',
    this.retailPrice,
    this.costPrice,
    this.imageUrl = '',
    this.status = 1,
  });

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
}

final class UpdateAdminProductRequest {
  const UpdateAdminProductRequest({
    required this.id,
    required this.code,
    required this.name,
    required this.unit,
    this.category = '',
    this.spec = '',
    this.barcode = '',
    this.retailPrice,
    this.costPrice,
    this.imageUrl = '',
    this.status,
  });

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
  final int? status;
}
