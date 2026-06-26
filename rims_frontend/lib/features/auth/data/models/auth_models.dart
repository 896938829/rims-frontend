import '../../domain/entities/app_user.dart';
import '../../domain/entities/warehouse.dart';

final class LoginResponseModel {
  const LoginResponseModel({required this.token, required this.user});

  factory LoginResponseModel.fromJson(Map<dynamic, dynamic> json) {
    return LoginResponseModel(
      token: json['token'] as String? ?? '',
      user: AppUserModel.fromJson(json['user'] as Map<dynamic, dynamic>? ?? {}),
    );
  }

  final String token;
  final AppUserModel user;
}

final class AppUserModel {
  const AppUserModel({
    required this.id,
    required this.username,
    required this.realName,
    required this.roleCode,
    required this.roleName,
  });

  factory AppUserModel.fromJson(Map<dynamic, dynamic> json) {
    return AppUserModel(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      realName: json['realName'] as String? ?? '',
      roleCode: json['roleCode'] as String? ?? '',
      roleName: json['roleName'] as String? ?? '',
    );
  }

  final int id;
  final String username;
  final String realName;
  final String roleCode;
  final String roleName;

  AppUser toEntity() {
    return AppUser(
      id: id,
      username: username,
      realName: realName.isNotEmpty ? realName : username,
      roleCode: roleCode,
      roleName: roleName,
    );
  }
}

final class WarehouseModel {
  const WarehouseModel({
    required this.id,
    required this.code,
    required this.name,
    required this.isDefault,
  });

  factory WarehouseModel.fromJson(Map<dynamic, dynamic> json) {
    return WarehouseModel(
      id: json['id'] as int? ?? 0,
      code: json['code'] as String? ?? '',
      name: json['name'] as String? ?? '',
      isDefault:
          json['isDefault'] as bool? ??
          json['isDefaultWarehouse'] as bool? ??
          false,
    );
  }

  final int id;
  final String code;
  final String name;
  final bool isDefault;

  Warehouse toEntity() {
    return Warehouse(id: id, code: code, name: name, isDefault: isDefault);
  }
}
