import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/network/auth_request_policy.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_permission_policy.dart';

void main() {
  test('login maps backend permissionCodes fixture', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"token":"jwt","expiresAt":1770000000,"user":{"id":7,"username":"alice","realName":"Alice","roleCode":"operator","roleName":"Operator","permissionCodes":["document:create","file:upload"]}}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.login(
      username: 'alice',
      password: 'secret',
    );

    expect(adapter.lastPath, '/auth/login');
    result.when(
      success: (login) {
        expect(login.user.permissionCodes, {'document:create', 'file:upload'});
        expect(
          const OutboxPermissionPolicy()
              .contextFor(user: login.user.toEntity(), warehouseId: 11)
              .allowedKinds,
          {
            OutboxOperationKind.attachmentUpload,
            OutboxOperationKind.documentCreate,
          },
        );
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('refresh posts the rotating credential without authorization', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"accessToken":"next-access","refreshToken":"next-refresh","accessExpiresAt":1784082600,"refreshExpiresAt":1786674600,"tokenVersion":6,"session":{"id":"session-7","deviceLabel":"Tablet","platform":"android","userAgentFamily":"RIMS","createdAt":"2026-07-15T02:00:00Z","lastUsedAt":"2026-07-15T02:01:00Z","expiresAt":"2026-08-14T02:00:00Z","current":true},"user":{"id":7,"username":"alice","roleCode":"operator","roleName":"Operator"}}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.refresh(refreshToken: 'current-refresh');

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/auth/refresh');
    expect(adapter.lastAuthorization, isNull);
    expect(adapter.lastBody, contains('current-refresh'));
    expect(adapter.lastExtra?[AuthRequestPolicy.skipRefresh], isTrue);
  });

  test('logout uses its captured token and cannot enter refresh', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"success","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(
        dio: dio,
        tokenReader: () async => 'new-session-access',
        enableLogging: false,
      ),
    );

    final result = await dataSource.logout(accessToken: 'old-session-access');

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/auth/logout');
    expect(adapter.lastAuthorization, 'Bearer old-session-access');
    expect(adapter.lastExtra?[AuthRequestPolicy.skipRefresh], isTrue);
  });

  test(
    'loadCurrentUser maps refreshed backend permissionCodes fixture',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"id":1,"username":"admin","realName":"Admin","roleId":1,"roleCode":"admin","roleName":"Administrator","permissionCodes":["document:create","document:complete","stocktake:confirm","stocktake:settle","file:upload"]}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadCurrentUser();

      expect(adapter.lastPath, '/users/me');
      result.when(
        success: (user) {
          expect(user.permissionCodes, {
            'document:create',
            'document:complete',
            'stocktake:confirm',
            'stocktake:settle',
            'file:upload',
          });
          expect(
            const OutboxPermissionPolicy()
                .contextFor(user: user.toEntity(), warehouseId: 11)
                .allowedKinds,
            OutboxOperationKind.values.toSet(),
          );
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test('login rejects success envelope with non-object payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":"bad-login-payload"}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.login(
      username: 'alice',
      password: 'secret',
    );

    expect(result.isFailure, isTrue);
    expect(adapter.lastPath, '/auth/login');
    result.when(
      success: (_) => fail('Expected login payload validation failure'),
      failure: (failure) => expect(failure.message, 'Invalid login response'),
    );
  });

  test(
    'loadCurrentUser rejects success envelope with non-object payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":["bad-user-payload"]}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadCurrentUser();

      expect(result.isFailure, isTrue);
      expect(adapter.lastPath, '/users/me');
      result.when(
        success: (_) =>
            fail('Expected current user payload validation failure'),
        failure: (failure) =>
            expect(failure.message, 'Invalid current user response'),
      );
    },
  );

  for (final listKey in const ['items', 'records', 'rows']) {
    test('loadWarehouses maps backend $listKey list response', () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"$listKey":[{"warehouseId":2,"isDefault":true,"warehouse":{"id":2,"code":"BJ","name":"北京仓"}}],"total":1}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadWarehouses();

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/users/me/warehouses');
      result.when(
        success: (warehouses) {
          expect(warehouses, hasLength(1));
          expect(warehouses.single.id, 2);
          expect(warehouses.single.code, 'BJ');
          expect(warehouses.single.name, '北京仓');
          expect(warehouses.single.isDefault, isTrue);
        },
        failure: (failure) => fail(failure.message),
      );
    });
  }

  test(
    'loadWarehouses maps string warehouse ids from backend response',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"warehouses":[{"warehouseId":"2","isDefaultWarehouse":true,"warehouse":{"id":"2","code":1001,"name":"北京仓"}}]}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadWarehouses();

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/users/me/warehouses');
      result.when(
        success: (warehouses) {
          expect(warehouses.single.id, 2);
          expect(warehouses.single.code, '1001');
          expect(warehouses.single.name, '北京仓');
          expect(warehouses.single.isDefault, isTrue);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'loadWarehouses rejects success envelope without list payload',
    () async {
      await _expectWarehouseListFailure(
        body: '{"code":0,"message":"ok","data":null}',
        expectedMessage: 'Invalid warehouses response',
      );
    },
  );

  test(
    'loadWarehouses rejects success envelope with non-object item',
    () async {
      await _expectWarehouseListFailure(
        body: '{"code":0,"message":"ok","data":{"list":["bad-item"]}}',
        expectedMessage: 'Invalid warehouses response',
      );
    },
  );

  test(
    'begin login maps an opaque second-factor challenge without tokens',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"token":"","accessToken":"","refreshToken":"","secondFactorRequired":true,"secondFactorChallenge":"abcdefghijklmnopqrstuvwxyzABCDEFGH123456789","secondFactorExpiresAt":1784189100,"session":{},"user":{}}}',
      );
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = adapter,
          enableLogging: false,
        ),
      );

      final result = await dataSource.beginLogin(
        username: 'alice',
        password: 'secret',
      );

      expect(adapter.lastPath, '/auth/login');
      expect(result, isA<Success<LoginStartResponseModel>>());
      final challenge = (result as Success<LoginStartResponseModel>).data;
      expect(challenge, isA<LoginChallengeResponseModel>());
      final typedChallenge = challenge as LoginChallengeResponseModel;
      expect(typedChallenge.challenge, hasLength(43));
      expect(typedChallenge.expiresAt, DateTime.utc(2026, 7, 16, 8, 5));
    },
  );

  test(
    'challenge completion sends exactly one factor to centralized route',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"accessToken":"access","refreshToken":"refresh","accessExpiresAt":1784190000,"refreshExpiresAt":1786782000,"tokenVersion":3,"session":{"id":"session-7","createdAt":"2026-07-16T03:00:00Z","lastUsedAt":"2026-07-16T03:00:00Z","expiresAt":"2026-08-15T03:00:00Z","current":true},"user":{"id":7,"username":"alice"}}}',
      );
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = adapter,
          enableLogging: false,
        ),
      );

      final result = await dataSource.completeSecondFactorChallenge(
        challenge: 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789',
        recoveryCode: 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE',
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/auth/2fa/challenge/complete');
      expect(adapter.lastBody, contains('recoveryCode'));
      expect(adapter.lastBody, isNot(contains('"code"')));
    },
  );

  test(
    'second-factor management routes map status enrollment and recovery codes',
    () async {
      final statusAdapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"enabled":true,"pending":false,"recoveryCodesRemaining":7}}',
      );
      final statusSource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = statusAdapter,
          enableLogging: false,
        ),
      );
      final status = await statusSource.getSecondFactorStatus();
      expect(status.isSuccess, isTrue);
      expect(statusAdapter.lastPath, '/auth/2fa/status');

      final enrollmentAdapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"secret":"JBSWY3DPEHPK3PXP","otpauthUri":"otpauth://totp/RIMS:alice?secret=JBSWY3DPEHPK3PXP","expiresAt":"2026-07-16T03:10:00Z"}}',
      );
      final enrollmentSource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = enrollmentAdapter,
          enableLogging: false,
        ),
      );
      final enrollment = await enrollmentSource.beginSecondFactorEnrollment();
      expect(enrollment.isSuccess, isTrue);
      expect(enrollmentAdapter.lastPath, '/auth/2fa/enrollment');

      final recoveryAdapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"recoveryCodes":["AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE"]}}',
      );
      final recoverySource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = recoveryAdapter,
          enableLogging: false,
        ),
      );
      final recovery = await recoverySource.confirmSecondFactorEnrollment(
        code: '123456',
      );
      expect(recovery.isSuccess, isTrue);
      expect(recoveryAdapter.lastPath, '/auth/2fa/enrollment/confirm');
    },
  );

  test(
    'switchCurrentWarehouse accepts success envelope without warehouse payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.switchCurrentWarehouse(2);

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/users/me/warehouses/current');
      result.when(
        success: (warehouse) => expect(warehouse, isNull),
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'login bootstrap warehouse request uses only its explicit token',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{"list":[]}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(
          dio: dio,
          tokenReader: () async => throw StateError('global token gate closed'),
          enableLogging: false,
        ),
      );

      final result = await dataSource.loadWarehouses(
        accessToken: 'fresh-response-token',
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.lastAuthorization, 'Bearer fresh-response-token');
    },
  );

  test('device sessions map the backend safe projection exactly', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":[{"id":"session-7","deviceLabel":"Warehouse tablet","platform":"android","userAgentFamily":"RIMS Android","createdAt":"2026-07-01T08:00:00Z","lastUsedAt":"2026-07-15T09:30:00Z","expiresAt":"2026-08-01T08:00:00Z","current":true}]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listDeviceSessions();

    expect(adapter.lastPath, '/auth/sessions');
    result.when(
      success: (sessions) {
        expect(sessions.single.id, 'session-7');
        expect(sessions.single.deviceLabel, 'Warehouse tablet');
        expect(sessions.single.platform, 'android');
        expect(sessions.single.userAgentFamily, 'RIMS Android');
        expect(sessions.single.current, isTrue);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('revoke one encodes the session id and accepts backend 204', () async {
    final adapter = _CapturingAdapter(body: '', statusCode: 204);
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.revokeDeviceSession('session/7');

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'DELETE');
    expect(adapter.lastPath, '/auth/sessions/session%2F7');
  });

  for (final command in const {'revoke-others': 2, 'revoke-all': 3}.entries) {
    test('${command.key} returns the backend revoked count', () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{"revoked":${command.value}}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = command.key == 'revoke-others'
          ? await dataSource.revokeOtherDeviceSessions()
          : await dataSource.revokeAllDeviceSessions();

      expect(adapter.lastMethod, 'POST');
      expect(adapter.lastPath, '/auth/sessions/${command.key}');
      result.when(
        success: (count) => expect(count, command.value),
        failure: (failure) => fail(failure.message),
      );
    });
  }

  for (final invalidCount in const ['1.0', '-1', '"1"', 'NaN', 'Infinity']) {
    test('revoke count rejects $invalidCount with a typed failure', () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{"revoked":$invalidCount}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.revokeAllDeviceSessions();

      expect(result, isA<FailureResult<int>>());
    });
  }
}

Future<void> _expectWarehouseListFailure({
  required String body,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiAuthRemoteDataSource(
    ApiClient.test(dio: dio, enableLogging: false),
  );

  final Result<List<WarehouseModel>> result = await dataSource.loadWarehouses();

  expect(result.isFailure, isTrue);
  expect(adapter.lastPath, '/users/me/warehouses');
  result.when(
    success: (_) => fail('Expected warehouses payload validation failure'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.body, this.statusCode = 200});

  final String body;
  final int statusCode;
  String? lastPath;
  String? lastMethod;
  String? lastAuthorization;
  String? lastBody;
  Map<String, dynamic>? lastExtra;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
    lastAuthorization = options.headers['Authorization']?.toString();
    lastExtra = Map<String, dynamic>.from(options.extra);
    if (requestStream != null) {
      lastBody = utf8.decode(
        await requestStream.expand((bytes) => bytes).toList(),
      );
    }

    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
