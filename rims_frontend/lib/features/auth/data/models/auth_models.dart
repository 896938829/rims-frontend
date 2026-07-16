import 'dart:convert';

import '../../domain/entities/app_user.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/entities/second_factor.dart';
import '../../domain/entities/warehouse.dart';

sealed class LoginStartResponseModel {
  const LoginStartResponseModel();
}

final class LoginChallengeResponseModel extends LoginStartResponseModel {
  const LoginChallengeResponseModel({
    required this.challenge,
    required this.expiresAt,
  });

  factory LoginChallengeResponseModel.fromJson(Map<dynamic, dynamic> json) {
    final challenge = _readString(json, const ['secondFactorChallenge']);
    final expiresAt = _readDateTime(json, const ['secondFactorExpiresAt']);
    if (challenge == null || challenge.length != 43 || expiresAt == null) {
      throw const FormatException('Invalid second-factor challenge response');
    }
    return LoginChallengeResponseModel(
      challenge: challenge,
      expiresAt: expiresAt,
    );
  }

  final String challenge;
  final DateTime expiresAt;
}

final class LoginResponseModel extends LoginStartResponseModel {
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

final class SecondFactorStatusModel {
  const SecondFactorStatusModel({
    required this.enabled,
    required this.pending,
    required this.recoveryCodesRemaining,
    this.pendingUntil,
  });

  factory SecondFactorStatusModel.fromJson(Map<dynamic, dynamic> json) {
    final enabled = _readBool(json, const ['enabled']);
    final pending = _readBool(json, const ['pending']);
    final remaining = _readInt(json, const ['recoveryCodesRemaining']);
    if (enabled == null ||
        pending == null ||
        remaining == null ||
        remaining < 0) {
      throw const FormatException('Invalid second-factor status response');
    }
    return SecondFactorStatusModel(
      enabled: enabled,
      pending: pending,
      recoveryCodesRemaining: remaining,
      pendingUntil: _readDateTime(json, const ['pendingUntil']),
    );
  }

  final bool enabled;
  final bool pending;
  final int recoveryCodesRemaining;
  final DateTime? pendingUntil;

  SecondFactorStatus toEntity() => SecondFactorStatus(
    enabled: enabled,
    pending: pending,
    recoveryCodesRemaining: recoveryCodesRemaining,
    pendingUntil: pendingUntil,
  );
}

final class TOTPEnrollmentModel {
  const TOTPEnrollmentModel({
    required this.secret,
    required this.otpAuthUri,
    required this.expiresAt,
  });

  factory TOTPEnrollmentModel.fromJson(Map<dynamic, dynamic> json) {
    final secret = _readString(json, const ['secret']);
    final uriValue = _readString(json, const ['otpauthUri']);
    final expiresAt = _readDateTime(json, const ['expiresAt']);
    final uri = uriValue == null ? null : Uri.tryParse(uriValue);
    if (secret == null ||
        uri == null ||
        uri.scheme != 'otpauth' ||
        expiresAt == null) {
      throw const FormatException('Invalid TOTP enrollment response');
    }
    return TOTPEnrollmentModel(
      secret: secret,
      otpAuthUri: uri,
      expiresAt: expiresAt,
    );
  }

  final String secret;
  final Uri otpAuthUri;
  final DateTime expiresAt;

  TOTPEnrollment toEntity() => TOTPEnrollment(
    secret: secret,
    otpAuthUri: otpAuthUri,
    expiresAt: expiresAt,
  );
}

final class RecoveryCodeSetModel {
  const RecoveryCodeSetModel(this.codes);

  factory RecoveryCodeSetModel.fromJson(Map<dynamic, dynamic> json) {
    final values = json['recoveryCodes'];
    if (values is! List ||
        values.isEmpty ||
        values.any((value) => value is! String || value.trim().isEmpty)) {
      throw const FormatException('Invalid recovery codes response');
    }
    return RecoveryCodeSetModel(
      values
          .cast<String>()
          .map((value) => value.trim())
          .toList(growable: false),
    );
  }

  final List<String> codes;

  RecoveryCodeSet toEntity() => RecoveryCodeSet(List.unmodifiable(codes));
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
    final current = _readBool(json, const ['current']);
    if (id == null ||
        createdAt == null ||
        lastUsedAt == null ||
        expiresAt == null ||
        current == null) {
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
      current: current,
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
