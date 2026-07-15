import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';

void main() {
  group('DeviceSessionModel', () {
    test('requires the backend current marker', () {
      expect(
        () => DeviceSessionModel.fromJson({
          'id': 'session-7',
          'deviceLabel': 'Warehouse tablet',
          'platform': 'android',
          'userAgentFamily': 'RIMS Android',
          'createdAt': '2026-07-01T08:00:00Z',
          'lastUsedAt': '2026-07-15T09:30:00Z',
          'expiresAt': '2026-08-01T08:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('maps the complete safe backend projection', () {
      final model = DeviceSessionModel.fromJson({
        'id': 'session-7',
        'deviceLabel': 'Warehouse tablet',
        'platform': 'android',
        'userAgentFamily': 'RIMS Android',
        'createdAt': '2026-07-01T08:00:00Z',
        'lastUsedAt': '2026-07-15T09:30:00Z',
        'expiresAt': '2026-08-01T08:00:00Z',
        'revokedAt': '2026-07-15T10:00:00Z',
        'current': true,
        'clientIp': '10.24.16.8',
        'tokenHash': 'must-not-cross-the-boundary',
      });

      final session = model.toEntity();
      expect(session.id, 'session-7');
      expect(session.deviceLabel, 'Warehouse tablet');
      expect(session.platform, 'android');
      expect(session.userAgentFamily, 'RIMS Android');
      expect(session.createdAt, DateTime.utc(2026, 7, 1, 8));
      expect(session.lastUsedAt, DateTime.utc(2026, 7, 15, 9, 30));
      expect(session.expiresAt, DateTime.utc(2026, 8, 1, 8));
      expect(session.revokedAt, DateTime.utc(2026, 7, 15, 10));
      expect(session.current, isTrue);
      expect(session.toString(), isNot(contains('10.24.16.8')));
      expect(
        session.toString(),
        isNot(contains('must-not-cross-the-boundary')),
      );
    });
  });

  group('LoginResponseModel', () {
    test('parses rotating backend credentials and device session', () {
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'ver': 5})))
          .replaceAll('=', '');
      final model = LoginResponseModel.fromJson({
        'token': 'legacy-token-alias',
        'accessToken': 'header.$payload.signature',
        'refreshToken': 'refresh-token',
        'accessExpiresAt': 1784082600,
        'refreshExpiresAt': 1786674600,
        'session': {
          'id': 'session-7',
          'deviceLabel': 'Warehouse tablet',
          'platform': 'android',
          'userAgentFamily': 'RIMS Android',
          'createdAt': '2026-07-15T02:00:00Z',
          'lastUsedAt': '2026-07-15T02:01:00Z',
          'expiresAt': '2026-08-14T02:00:00Z',
          'current': true,
        },
        'user': {
          'id': 7,
          'username': 'alice',
          'roleCode': 'operator',
          'roleName': 'Operator',
        },
      });

      expect(model.accessToken, 'header.$payload.signature');
      expect(model.token, 'header.$payload.signature');
      expect(model.refreshToken, 'refresh-token');
      expect(
        model.accessExpiresAt,
        DateTime.fromMillisecondsSinceEpoch(1784082600000, isUtc: true),
      );
      expect(
        model.refreshExpiresAt,
        DateTime.fromMillisecondsSinceEpoch(1786674600000, isUtc: true),
      );
      expect(model.tokenVersion, 5);
      expect(model.session?.id, 'session-7');
      expect(model.session?.deviceLabel, 'Warehouse tablet');
      expect(model.session?.current, isTrue);
    });

    test('parses accessToken and alternate user payload fields', () {
      final model = LoginResponseModel.fromJson({
        'accessToken': 'token-from-backend',
        'userInfo': {
          'userId': 7,
          'account': 'alice',
          'name': 'Alice Chen',
          'role': {'code': 'admin', 'name': '管理员'},
        },
      });

      expect(model.token, 'token-from-backend');
      expect(model.accessToken, 'token-from-backend');
      expect(model.refreshToken, isNull);
      expect(model.session, isNull);
      expect(model.user.id, 7);
      expect(model.user.username, 'alice');
      expect(model.user.realName, 'Alice Chen');
      expect(model.user.roleCode, 'admin');
      expect(model.user.roleName, '管理员');
    });
  });

  group('AppUserModel', () {
    test('parses current user aliases and nested role', () {
      final model = AppUserModel.fromJson({
        'userId': '8',
        'account': 'operator',
        'nickname': '一线操作员',
        'role': {'roleCode': 'user', 'roleName': '普通用户'},
      });

      expect(model.id, 8);
      expect(model.username, 'operator');
      expect(model.realName, '一线操作员');
      expect(model.roleCode, 'user');
      expect(model.roleName, '普通用户');
    });

    test('parses backend permissionCodes as a normalized set', () {
      final model = AppUserModel.fromJson({
        'id': 7,
        'username': 'operator',
        'roleCode': 'operator',
        'roleName': 'Operator',
        'permissionCodes': [
          'document:create',
          'file:upload',
          'document:create',
        ],
      });

      expect(model.permissionCodes, {'document:create', 'file:upload'});
      expect(model.toEntity().permissionCodes, model.permissionCodes);
    });

    test('includes permissions nested in the current role projection', () {
      final model = AppUserModel.fromJson({
        'id': 7,
        'username': 'operator',
        'role': {
          'code': 'operator',
          'name': 'Operator',
          'permissions': [
            {'code': 'document:complete'},
          ],
        },
      });

      expect(model.permissionCodes, {'document:complete'});
    });
  });

  group('WarehouseModel', () {
    test(
      'parses nested warehouse binding returned by current user endpoint',
      () {
        final model = WarehouseModel.fromJson({
          'id': 74,
          'warehouseId': 1,
          'isDefault': true,
          'warehouse': {'id': 1, 'code': 'WH001', 'name': '默认仓库', 'status': 1},
        });

        expect(model.id, 1);
        expect(model.code, 'WH001');
        expect(model.name, '默认仓库');
        expect(model.isDefault, isTrue);
      },
    );

    test('parses string ids returned by warehouse endpoints', () {
      final model = WarehouseModel.fromJson({
        'warehouseId': '2',
        'isDefaultWarehouse': true,
        'warehouse': {'id': '2', 'code': 1001, 'name': '北京仓'},
      });

      expect(model.id, 2);
      expect(model.code, '1001');
      expect(model.name, '北京仓');
      expect(model.isDefault, isTrue);
    });
  });
}
