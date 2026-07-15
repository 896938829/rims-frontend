import 'dart:convert';

import '../../domain/entities/app_user.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/entities/warehouse.dart';

final class LoginResponseModel {
  const LoginResponseModel({
    required String token,
    required this.user,
    String? accessToken,
    this.refreshToken,
    this.accessExpiresAt,
    this.refreshExpiresAt,
    this.tokenVersion,
    this.session,
  }) : accessToken = accessToken ?? token,
       token = accessToken ?? token;

  factory LoginResponseModel.fromJson(Map<dynamic, dynamic> json) {
    final userJson =
        _readMap(json, const ['user', 'userInfo', 'currentUser', 'profile']) ??
        json;

    final accessToken =
        _readString(json, const [
          'accessToken',
          'access_token',
          'token',
          'jwt',
        ]) ??
        '';
    final sessionJson = _readMap(json, const ['session']);
    return LoginResponseModel(
      token: accessToken,
      accessToken: accessToken,
      refreshToken: _readString(json, const ['refreshToken', 'refresh_token']),
      accessExpiresAt: _readDateTime(json, const [
        'accessExpiresAt',
        'expiresAt',
        'access_expires_at',
      ]),
      refreshExpiresAt: _readDateTime(json, const [
        'refreshExpiresAt',
        'refresh_expires_at',
      ]),
      tokenVersion:
          _readInt(json, const ['tokenVersion', 'token_version']) ??
          _readJwtTokenVersion(accessToken),
      session: sessionJson == null
          ? null
          : DeviceSessionModel.fromJson(sessionJson),
      user: AppUserModel.fromJson(userJson),
    );
  }

  final String token;
  final String accessToken;
  final String? refreshToken;
  final DateTime? accessExpiresAt;
  final DateTime? refreshExpiresAt;
  final int? tokenVersion;
  final DeviceSessionModel? session;
  final AppUserModel user;

  bool get hasRotatingCredential =>
      refreshToken != null &&
      accessExpiresAt != null &&
      refreshExpiresAt != null &&
      tokenVersion != null &&
      session != null;
}

final class DeviceSessionModel {
  const DeviceSessionModel({
    required this.id,
    required this.deviceLabel,
    required this.platform,
    required this.userAgentFamily,
    required this.createdAt,
    required this.lastUsedAt,
    required this.expiresAt,
    required this.current,
    this.revokedAt,
  });

  factory DeviceSessionModel.fromJson(Map<dynamic, dynamic> json) {
    final id = _readString(json, const ['id', 'sessionId', 'session_id']);
    final createdAt = _readDateTime(json, const ['createdAt', 'created_at']);
    final lastUsedAt = _readDateTime(json, const [
      'lastUsedAt',
      'last_used_at',
    ]);
    final expiresAt = _readDateTime(json, const ['expiresAt', 'expires_at']);
    if (id == null ||
        createdAt == null ||
        lastUsedAt == null ||
        expiresAt == null) {
      throw const FormatException('Invalid device session response');
    }
    return DeviceSessionModel(
      id: id,
      deviceLabel:
          _readString(json, const ['deviceLabel', 'device_label']) ??
          'Unknown device',
      platform: _readString(json, const ['platform']) ?? 'unknown',
      userAgentFamily:
          _readString(json, const ['userAgentFamily', 'user_agent_family']) ??
          'unknown',
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
      expiresAt: expiresAt,
      revokedAt: _readDateTime(json, const ['revokedAt', 'revoked_at']),
      current: _readBool(json, const ['current']) ?? false,
    );
  }

  final String id;
  final String deviceLabel;
  final String platform;
  final String userAgentFamily;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final bool current;

  DeviceSession toEntity() => DeviceSession(
    id: id,
    deviceLabel: deviceLabel,
    platform: platform,
    userAgentFamily: userAgentFamily,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt,
    expiresAt: expiresAt,
    revokedAt: revokedAt,
    current: current,
  );
}

final class AppUserModel {
  const AppUserModel({
    required this.id,
    required this.username,
    required this.realName,
    required this.roleCode,
    required this.roleName,
    this.permissionCodes = const {},
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
      permissionCodes: _readPermissionCodes([json, roleJson]),
    );
  }

  final int id;
  final String username;
  final String realName;
  final String roleCode;
  final String roleName;
  final Set<String> permissionCodes;

  AppUser toEntity() {
    return AppUser(
      id: id,
      username: username,
      realName: realName.isNotEmpty ? realName : username,
      roleCode: roleCode,
      roleName: roleName,
      permissionCodes: permissionCodes,
    );
  }
}

Set<String> _readPermissionCodes(Iterable<Map<dynamic, dynamic>> sources) {
  final codes = <String>{};
  for (final source in sources) {
    for (final key in const [
      'permissions',
      'permissionCodes',
      'capabilities',
    ]) {
      final values = source[key];
      if (values is! List) continue;
      for (final value in values) {
        final raw = value is Map
            ? _readString(value, const [
                'code',
                'permissionCode',
                'capability',
                'key',
                'value',
              ])
            : value?.toString();
        final normalized = raw?.trim().toLowerCase();
        if (normalized != null && normalized.isNotEmpty) codes.add(normalized);
      }
    }
  }
  return Set.unmodifiable(codes);
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

DateTime? _readDateTime(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      final milliseconds = value.abs() < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
    if (value is num) {
      final raw = value.round();
      final milliseconds = raw.abs() < 100000000000 ? raw * 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
  }
  return null;
}

int? _readJwtTokenVersion(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    return payload is Map
        ? _readInt(payload, const ['ver', 'token_version'])
        : null;
  } on Object {
    return null;
  }
}
