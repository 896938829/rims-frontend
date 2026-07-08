final class AdminUser {
  const AdminUser({
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

  final int id;
  final String username;
  final String realName;
  final String phone;
  final String email;
  final int roleId;
  final String roleCode;
  final String roleName;
  final int status;

  bool get isActive => status == 1;
}

final class CreateAdminUserRequest {
  const CreateAdminUserRequest({
    required this.username,
    required this.password,
    required this.roleId,
    this.realName = '',
    this.phone = '',
    this.email = '',
  });

  final String username;
  final String password;
  final String realName;
  final String phone;
  final String email;
  final int roleId;
}

final class UpdateAdminUserRequest {
  const UpdateAdminUserRequest({
    required this.id,
    this.realName = '',
    this.phone = '',
    this.email = '',
    this.roleId,
    this.status,
  });

  final int id;
  final String realName;
  final String phone;
  final String email;
  final int? roleId;
  final int? status;
}

final class ChangeOwnPasswordRequest {
  const ChangeOwnPasswordRequest({
    required this.oldPassword,
    required this.newPassword,
  });

  final String oldPassword;
  final String newPassword;
}

final class ResetUserPasswordRequest {
  const ResetUserPasswordRequest({
    required this.userId,
    required this.newPassword,
  });

  final int userId;
  final String newPassword;
}
