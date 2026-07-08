import '../../domain/entities/admin_warehouse.dart';

final class AdminWarehouseModel {
  const AdminWarehouseModel({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.address,
    required this.contactPerson,
    required this.contactPhone,
  });

  factory AdminWarehouseModel.fromJson(Map<dynamic, dynamic> json) {
    return AdminWarehouseModel(
      id: _readInt(json, const ['id', 'warehouseId']) ?? 0,
      code: _readString(json, const ['code', 'warehouseCode']) ?? '',
      name: _readString(json, const ['name', 'warehouseName']) ?? '',
      status: _readInt(json, const ['status', 'state']) ?? 0,
      address: _readString(json, const ['address']) ?? '',
      contactPerson:
          _readString(json, const ['contactPerson', 'managerName']) ?? '',
      contactPhone:
          _readString(json, const ['contactPhone', 'phone', 'mobile']) ?? '',
    );
  }

  final int id;
  final String code;
  final String name;
  final int status;
  final String address;
  final String contactPerson;
  final String contactPhone;

  AdminWarehouse toEntity() {
    return AdminWarehouse(
      id: id,
      code: code,
      name: name,
      status: status,
      address: address,
      contactPerson: contactPerson,
      contactPhone: contactPhone,
    );
  }
}

Map<String, Object> createAdminWarehouseRequestToJson(
  CreateAdminWarehouseRequest request,
) {
  return {
    'code': request.code.trim(),
    'name': request.name.trim(),
    'status': request.status,
    if (request.address.trim().isNotEmpty) 'address': request.address.trim(),
    if (request.contactPerson.trim().isNotEmpty)
      'contactPerson': request.contactPerson.trim(),
    if (request.contactPhone.trim().isNotEmpty)
      'contactPhone': request.contactPhone.trim(),
  };
}

Map<String, Object> updateAdminWarehouseRequestToJson(
  UpdateAdminWarehouseRequest request,
) {
  return {
    'code': request.code.trim(),
    'name': request.name.trim(),
    if (request.status != null) 'status': request.status!,
    if (request.address.trim().isNotEmpty) 'address': request.address.trim(),
    if (request.contactPerson.trim().isNotEmpty)
      'contactPerson': request.contactPerson.trim(),
    if (request.contactPhone.trim().isNotEmpty)
      'contactPhone': request.contactPhone.trim(),
  };
}

Map<String, Object> bindWarehouseUsersRequestToJson(
  BindWarehouseUsersRequest request,
) {
  return {'userIds': request.userIds};
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
    if (value is bool) {
      return value ? 1 : 0;
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
