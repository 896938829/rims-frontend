import '../../domain/entities/admin_user.dart';

final class AdminUserModel {
  const AdminUserModel({
    required this.id,
    required this.username,
    required this.realName,
    required this.phone,
    required this.email,
    required this.roleId,
    required this.roleCode,
    required this.roleName,
    required this.status,
  });

  factory AdminUserModel.fromJson(Map<dynamic, dynamic> json) {
    return AdminUserModel(
      id: _readInt(json, const ['id', 'userId']) ?? 0,
      username: _readString(json, const ['username', 'account']) ?? '',
      realName: _readString(json, const ['realName', 'name', 'nickname']) ?? '',
      phone: _readString(json, const ['phone', 'mobile']) ?? '',
      email: _readString(json, const ['email']) ?? '',
      roleId: _readInt(json, const ['roleId']) ?? 0,
      roleCode: _readString(json, const ['roleCode']) ?? '',
      roleName: _readString(json, const ['roleName']) ?? '',
      status: _readInt(json, const ['status', 'state']) ?? 0,
    );
  }

  final int id;
  final String username;
  final String realName;
  final String phone;
  final String email;
  final int roleId;
  final String roleCode;
  final String roleName;
  final int status;

  AdminUser toEntity() {
    return AdminUser(
      id: id,
      username: username,
      realName: realName,
      phone: phone,
      email: email,
      roleId: roleId,
      roleCode: roleCode,
      roleName: roleName,
      status: status,
    );
  }
}

Map<String, Object> createAdminUserRequestToJson(
  CreateAdminUserRequest request,
) {
  return {
    'username': request.username.trim(),
    'password': request.password,
    if (request.realName.trim().isNotEmpty) 'realName': request.realName.trim(),
    if (request.phone.trim().isNotEmpty) 'phone': request.phone.trim(),
    if (request.email.trim().isNotEmpty) 'email': request.email.trim(),
    'roleId': request.roleId,
  };
}

Map<String, Object> updateAdminUserRequestToJson(
  UpdateAdminUserRequest request,
) {
  return {
    if (request.realName.trim().isNotEmpty) 'realName': request.realName.trim(),
    if (request.phone.trim().isNotEmpty) 'phone': request.phone.trim(),
    if (request.email.trim().isNotEmpty) 'email': request.email.trim(),
    if (request.roleId != null) 'roleId': request.roleId!,
    if (request.status != null) 'status': request.status!,
  };
}

Map<String, Object> changeOwnPasswordRequestToJson(
  ChangeOwnPasswordRequest request,
) {
  return {
    'oldPassword': request.oldPassword,
    'newPassword': request.newPassword,
  };
}

Map<String, Object> resetUserPasswordRequestToJson(
  ResetUserPasswordRequest request,
) {
  return {'newPassword': request.newPassword};
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
