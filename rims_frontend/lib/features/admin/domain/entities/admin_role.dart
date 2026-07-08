final class AdminRole {
  const AdminRole({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    this.permissionIds = const [],
  });

  final int id;
  final String code;
  final String name;
  final int status;
  final List<int> permissionIds;

  bool get isActive => status == 1;

  AdminRole copyWith({List<int>? permissionIds}) {
    return AdminRole(
      id: id,
      code: code,
      name: name,
      status: status,
      permissionIds: permissionIds ?? this.permissionIds,
    );
  }
}

final class AdminPermission {
  const AdminPermission({
    required this.id,
    required this.code,
    required this.name,
    required this.group,
    required this.description,
  });

  final int id;
  final String code;
  final String name;
  final String group;
  final String description;
}

final class UpdateRolePermissionsRequest {
  const UpdateRolePermissionsRequest({
    required this.roleId,
    required this.permissionIds,
  });

  final int roleId;
  final List<int> permissionIds;
}
