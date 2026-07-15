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

  test('logout posts the authenticated session revocation endpoint', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"success","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient.test(
        dio: dio,
        tokenReader: () async => 'active-access',
        enableLogging: false,
      ),
    );

    final result = await dataSource.logout();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/auth/logout');
    expect(adapter.lastAuthorization, 'Bearer active-access');
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
  _CapturingAdapter({required this.body});

  final String body;
  String? lastPath;
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
    lastAuthorization = options.headers['Authorization']?.toString();
    lastExtra = Map<String, dynamic>.from(options.extra);
    if (requestStream != null) {
      lastBody = utf8.decode(
        await requestStream.expand((bytes) => bytes).toList(),
      );
    }

    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
