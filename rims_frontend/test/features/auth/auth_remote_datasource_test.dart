import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';

void main() {
  test('login rejects success envelope with non-object payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":"bad-login-payload"}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
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

  test('loadCurrentUser rejects success envelope with non-object payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":["bad-user-payload"]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadCurrentUser();

    expect(result.isFailure, isTrue);
    expect(adapter.lastPath, '/users/me');
    result.when(
      success: (_) => fail('Expected current user payload validation failure'),
      failure: (failure) =>
          expect(failure.message, 'Invalid current user response'),
    );
  });

  for (final listKey in const ['items', 'records', 'rows']) {
    test('loadWarehouses maps backend $listKey list response', () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"$listKey":[{"warehouseId":2,"isDefault":true,"warehouse":{"id":2,"code":"BJ","name":"北京仓"}}],"total":1}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
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

  test('loadWarehouses maps string warehouse ids from backend response', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"warehouses":[{"warehouseId":"2","isDefaultWarehouse":true,"warehouse":{"id":"2","code":1001,"name":"北京仓"}}]}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAuthRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
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
  });

  test('loadWarehouses rejects success envelope without list payload', () async {
    await _expectWarehouseListFailure(
      body: '{"code":0,"message":"ok","data":null}',
      expectedMessage: 'Invalid warehouses response',
    );
  });

  test('loadWarehouses rejects success envelope with non-object item', () async {
    await _expectWarehouseListFailure(
      body: '{"code":0,"message":"ok","data":{"list":["bad-item"]}}',
      expectedMessage: 'Invalid warehouses response',
    );
  });

  test(
    'switchCurrentWarehouse accepts success envelope without warehouse payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAuthRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
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
}

Future<void> _expectWarehouseListFailure({
  required String body,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(body: body);
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiAuthRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
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

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;

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
