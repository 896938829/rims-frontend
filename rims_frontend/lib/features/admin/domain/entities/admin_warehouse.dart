final class AdminWarehouse {
  const AdminWarehouse({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.address,
    required this.contactPerson,
    required this.contactPhone,
  });

  final int id;
  final String code;
  final String name;
  final int status;
  final String address;
  final String contactPerson;
  final String contactPhone;

  bool get isActive => status == 1;
}

final class CreateAdminWarehouseRequest {
  const CreateAdminWarehouseRequest({
    required this.code,
    required this.name,
    this.status = 1,
    this.address = '',
    this.contactPerson = '',
    this.contactPhone = '',
  });

  final String code;
  final String name;
  final int status;
  final String address;
  final String contactPerson;
  final String contactPhone;
}

final class UpdateAdminWarehouseRequest {
  const UpdateAdminWarehouseRequest({
    required this.id,
    required this.code,
    required this.name,
    this.status,
    this.address = '',
    this.contactPerson = '',
    this.contactPhone = '',
  });

  final int id;
  final String code;
  final String name;
  final int? status;
  final String address;
  final String contactPerson;
  final String contactPhone;
}

final class BindWarehouseUsersRequest {
  const BindWarehouseUsersRequest({
    required this.warehouseId,
    required this.userIds,
  });

  final int warehouseId;
  final List<int> userIds;
}
