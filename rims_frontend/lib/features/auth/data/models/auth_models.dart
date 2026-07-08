import '../../domain/entities/app_user.dart';
import '../../domain/entities/warehouse.dart';

final class LoginResponseModel {
  const LoginResponseModel({required this.token, required this.user});

  factory LoginResponseModel.fromJson(Map<dynamic, dynamic> json) {
    final userJson =
        _readMap(json, const ['user', 'userInfo', 'currentUser', 'profile']) ??
        json;

    return LoginResponseModel(
      token:
          _readString(json, const [
            'token',
            'accessToken',
            'access_token',
            'jwt',
          ]) ??
          '',
      user: AppUserModel.fromJson(userJson),
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
    final roleJson = _readRoleMap(json);

    return AppUserModel(
      id: _readInt(json, const ['id', 'userId', 'uid']) ?? 0,
      username:
          _readString(json, const [
            'username',
            'userName',
            'account',
            'loginName',
            'name',
          ]) ??
          '',
      realName:
          _readString(json, const [
            'realName',
            'nickname',
            'displayName',
            'name',
          ]) ??
          '',
      roleCode:
          _readString(json, const ['roleCode', 'role_code', 'role']) ??
          _readString(roleJson, const ['roleCode', 'code', 'role_code']) ??
          '',
      roleName:
          _readString(json, const ['roleName', 'role_name', 'roleLabel']) ??
          _readString(roleJson, const ['roleName', 'name', 'role_name']) ??
          '',
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
    final warehouseJson = _readMap(json, const ['warehouse']);
    final source = warehouseJson ?? json;

    return WarehouseModel(
      id:
          _readInt(source, const ['id', 'warehouseId']) ??
          _readInt(json, const ['warehouseId']) ??
          0,
      code: _readString(source, const ['code', 'warehouseCode']) ?? '',
      name: _readString(source, const ['name', 'warehouseName']) ?? '',
      isDefault:
          _readBool(json, const ['isDefault', 'isDefaultWarehouse']) ??
          _readBool(source, const ['isDefault', 'isDefaultWarehouse']) ??
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

Map<dynamic, dynamic>? _readMap(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is Map<dynamic, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<dynamic, dynamic>.from(value);
    }
  }

  return null;
}

Map<dynamic, dynamic> _readRoleMap(Map<dynamic, dynamic> json) {
  final role = _readMap(json, const ['role']);
  if (role != null) {
    return role;
  }

  final roles = json['roles'];
  if (roles is List) {
    for (final candidate in roles) {
      if (candidate is Map<dynamic, dynamic>) {
        return candidate;
      }
      if (candidate is Map) {
        return Map<dynamic, dynamic>.from(candidate);
      }
    }
  }

  return const {};
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

bool? _readBool(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
  }

  return null;
}
