import '../../domain/entities/admin_role.dart';

final class AdminRoleModel {
  const AdminRoleModel({
    required this.id,
    required this.code,
    required this.name,
    required this.status,
    required this.permissionIds,
  });

  factory AdminRoleModel.fromJson(Map<dynamic, dynamic> json) {
    return AdminRoleModel(
      id: _readInt(json, const ['id', 'roleId']) ?? 0,
      code: _readString(json, const ['code', 'roleCode']) ?? '',
      name: _readString(json, const ['name', 'roleName']) ?? '',
      status: _readInt(json, const ['status', 'state']) ?? 0,
      permissionIds: _readPermissionIds(json),
    );
  }

  final int id;
  final String code;
  final String name;
  final int status;
  final List<int> permissionIds;

  AdminRole toEntity() {
    return AdminRole(
      id: id,
      code: code,
      name: name,
      status: status,
      permissionIds: permissionIds,
    );
  }
}

final class AdminPermissionModel {
  const AdminPermissionModel({
    required this.id,
    required this.code,
    required this.name,
    required this.group,
    required this.description,
  });

  factory AdminPermissionModel.fromJson(Map<dynamic, dynamic> json) {
    return AdminPermissionModel(
      id: _readInt(json, const ['id', 'permissionId']) ?? 0,
      code:
          _readString(json, const ['code', 'permissionCode', 'key', 'value']) ??
          '',
      name: _readString(json, const ['name', 'permissionName', 'label']) ?? '',
      group:
          _readString(json, const [
            'group',
            'groupName',
            'module',
            'moduleName',
          ]) ??
          '',
      description: _readString(json, const ['description', 'desc']) ?? '',
    );
  }

  final int id;
  final String code;
  final String name;
  final String group;
  final String description;

  AdminPermission toEntity() {
    return AdminPermission(
      id: id,
      code: code,
      name: name,
      group: group,
      description: description,
    );
  }
}

Map<String, Object> updateRolePermissionsRequestToJson(
  UpdateRolePermissionsRequest request,
) {
  return {'permissionIds': request.permissionIds};
}

List<int> _readPermissionIds(Map<dynamic, dynamic> json) {
  final raw = json['permissionIds'] ?? json['permissionIdList'];
  if (raw is List) {
    return _readPermissionIdList(raw);
  }

  final permissions = json['permissions'];
  if (permissions is List) {
    return _readPermissionIdList(
      permissions.map((item) {
        if (item is Map) {
          return _readInt(item, const ['id', 'permissionId']);
        }

        return item;
      }),
    );
  }

  return const [];
}

List<int> _readPermissionIdList(Iterable<Object?> values) {
  return values
      .map((value) {
        final parsed = _readIntValue(value);
        if (parsed != null) {
          return parsed;
        }

        throw const FormatException('Invalid role response');
      })
      .toList(growable: false);
}

int? _readInt(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    final parsed = _readIntValue(value);
    if (parsed != null) {
      return parsed;
    }
  }

  return null;
}

int? _readIntValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value.trim()) ?? double.tryParse(value.trim())?.round();
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
