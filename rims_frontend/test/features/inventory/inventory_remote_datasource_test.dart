import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/data/datasources/inventory_remote_datasource.dart';

void main() {
  test('findProductByBarcode loads backend barcode endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":17,"warehouseId":1,"productId":10,"quantity":8,"lockedQty":2,"status":1,"product":{"id":10,"name":"矿泉水 550ml","code":"SKU-WA-550","barcode":"6901234567890","imageUrl":"","status":1}}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiInventoryRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.findProductByBarcode('6901234567890');

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/inventory/barcode/6901234567890');
    result.when(
      success: (item) {
        expect(item.id, 17);
        expect(item.productId, 10);
        expect(item.productName, '矿泉水 550ml');
        expect(item.sku, 'SKU-WA-550');
        expect(item.stockQuantity, 8);
        expect(item.availableQuantity, 6);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'findProductByBarcode rejects success envelope without product payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiInventoryRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.findProductByBarcode('6901234567890');

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) => fail(
          'findProductByBarcode should fail without backend inventory data',
        ),
        failure: (failure) =>
            expect(failure.message, 'Invalid inventory response'),
      );
    },
  );

  test('listInventoryAlerts loads inventory alerts endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":2,"productId":20,"productName":"低库存商品","sku":"SKU-LOW","availableQuantity":2,"stockQuantity":3,"statusLabel":"低库存"}],"total":1,"page":1,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiInventoryRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listInventoryAlerts();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/inventory/alerts');
    result.when(
      success: (page) {
        expect(page.items.single.productId, 20);
        expect(page.items.single.statusLabel, '低库存');
        expect(page.total, 1);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('listInventory keeps retail price from backend product data', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":1,"productId":10,"availableQuantity":8,"stockQuantity":10,"product":{"id":10,"name":"矿泉水 550ml","code":"SKU-WA-550","retailPrice":"6.50"}}],"total":45,"page":2,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiInventoryRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listInventory(keyword: '矿泉水', page: 2);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/inventory');
    result.when(
      success: (page) {
        expect(page.items.single.productId, 10);
        expect(page.items.single.retailPrice, 6.5);
        expect(page.total, 45);
        expect(page.page, 2);
        expect(page.pageSize, 20);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('inventory list endpoints send page and pageSize parameters', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[],"total":0,"page":1,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiInventoryRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    await dataSource.listInventory(keyword: ' SKU ', page: 2);
    expect(adapter.lastPath, '/inventory');
    expect(adapter.lastQuery, {'keyword': 'SKU', 'page': 2, 'pageSize': 20});

    await dataSource.listInventoryAlerts(page: 3);
    expect(adapter.lastPath, '/inventory/alerts');
    expect(adapter.lastQuery, {'page': 3, 'pageSize': 20});

    await dataSource.listNonStandardInventory(page: 4);
    expect(adapter.lastPath, '/non-std-inventory');
    expect(adapter.lastQuery, {'page': 4, 'pageSize': 20});
  });

  test(
    'inventory list endpoints reject success envelope without list payload',
    () async {
      await _expectMissingListPayload(
        load: (dataSource) =>
            dataSource.listInventory(keyword: ' SKU ', page: 2),
        expectedPath: '/inventory',
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayload(
        load: (dataSource) => dataSource.listInventoryAlerts(page: 2),
        expectedPath: '/inventory/alerts',
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayload(
        load: (dataSource) => dataSource.listNonStandardInventory(page: 2),
        expectedPath: '/non-std-inventory',
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
    },
  );

  test(
    'inventory list endpoints reject success envelope with non-object item',
    () async {
      await _expectNonObjectListItem(
        load: (dataSource) =>
            dataSource.listInventory(keyword: ' SKU ', page: 2),
        expectedPath: '/inventory',
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectNonObjectListItem(
        load: (dataSource) => dataSource.listInventoryAlerts(page: 2),
        expectedPath: '/inventory/alerts',
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectNonObjectListItem(
        load: (dataSource) => dataSource.listNonStandardInventory(page: 2),
        expectedPath: '/non-std-inventory',
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
    },
  );

  test(
    'listNonStandardInventory loads non-standard inventory endpoint',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"list":[{"id":11,"tempLabel":"TMP-001","description":"破损瓶","unit":"件","quantity":5,"convertedQty":1,"remainingQty":4,"status":1}],"total":25,"page":1,"pageSize":20}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiInventoryRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listNonStandardInventory();

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/non-std-inventory');
      result.when(
        success: (page) {
          expect(page.items.single.id, 11);
          expect(page.items.single.tempLabel, 'TMP-001');
          expect(page.items.single.remainingQuantity, 4);
          expect(page.total, 25);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test('updateInventorySettings sends threshold and status only', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":2,"productId":20,"productName":"低库存商品","sku":"SKU-LOW","availableQuantity":2,"stockQuantity":3,"statusLabel":"低库存","alertThreshold":8,"status":1}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiInventoryRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateInventorySettings(
      inventoryId: 2,
      alertThreshold: 8,
      status: 1,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/inventory/2');
    expect(jsonDecode(adapter.lastBody!), {'alertThreshold': 8, 'status': 1});
    result.when(
      success: (item) {
        expect(item.id, 2);
        expect(item.alertThreshold, 8);
        expect(item.status, 1);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'updateInventorySettings rejects success envelope without inventory payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiInventoryRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.updateInventorySettings(
        inventoryId: 2,
        alertThreshold: 8,
        status: 1,
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) => fail(
          'updateInventorySettings should fail without backend inventory data',
        ),
        failure: (failure) =>
            expect(failure.message, 'Invalid inventory response'),
      );
    },
  );
}

Future<void> _expectMissingListPayload<T>({
  required Future<Result<PageData<T>>> Function(ApiInventoryRemoteDataSource)
  load,
  required String expectedPath,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(
    body: '{"code":0,"message":"ok","data":null}',
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiInventoryRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
  );

  final result = await load(dataSource);

  expect(result.isFailure, isTrue);
  expect(adapter.lastPath, expectedPath);
  result.when(
    success: (_) => fail('Expected inventory list payload validation failure'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

Future<void> _expectNonObjectListItem<T>({
  required Future<Result<PageData<T>>> Function(ApiInventoryRemoteDataSource)
  load,
  required String expectedPath,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(
    body:
        '{"code":0,"message":"ok","data":{"list":["bad-item"],"total":1,"page":1,"pageSize":20}}',
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiInventoryRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
  );

  final result = await load(dataSource);

  expect(result.isFailure, isTrue);
  expect(adapter.lastPath, expectedPath);
  result.when(
    success: (_) => fail('Expected inventory list item validation failure'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.body});

  final String body;
  String? lastPath;
  String? lastMethod;
  String? lastBody;
  Map<String, dynamic>? lastQuery;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
    lastQuery = Map<String, dynamic>.from(options.queryParameters);
    if (requestStream != null) {
      final bodyBytes = <int>[];
      await for (final chunk in requestStream) {
        bodyBytes.addAll(chunk);
      }
      lastBody = utf8.decode(bodyBytes);
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
