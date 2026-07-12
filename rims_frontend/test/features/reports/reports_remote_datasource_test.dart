import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/reports/data/datasources/reports_remote_datasource.dart';

void main() {
  test('loadSalesStats loads sales stats endpoint with date range', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"revenue":12345.5,"orderCount":8,"skuCount":3,"quantity":32,"costAmount":10000,"grossProfit":2345.5}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadSalesStats(
      startDate: DateTime(2026, 6),
      endDate: DateTime(2026, 6, 26),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/sales/stats');
    expect(adapter.lastQuery?['startDate'], '2026-06-01');
    expect(adapter.lastQuery?['endDate'], '2026-06-26');
    result.when(
      success: (stats) {
        expect(stats.revenue, 12345.5);
        expect(stats.orderCount, 8);
        expect(stats.skuCount, 3);
        expect(stats.quantity, 32);
        expect(stats.costAmount, 10000);
        expect(stats.grossProfit, 2345.5);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'loadSalesStats rejects success envelope without stats payload',
    () async {
      final adapter = _CapturingAdapter(body: '{"code":0,"message":"ok"}');
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiReportsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadSalesStats(
        startDate: DateTime(2026, 6),
        endDate: DateTime(2026, 6, 26),
      );

      expect(result.isFailure, isTrue);
      expect(adapter.lastPath, '/reports/sales/stats');
      result.when(
        success: (_) => fail('Expected sales stats payload validation failure'),
        failure: (failure) =>
            expect(failure.message, 'Invalid sales stats response'),
      );
    },
  );

  test('loadSalesTrend maps backend period and revenue fields', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"period":"2026-06-25","revenue":100.5},{"period":"2026-06-26","revenue":230}]}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadSalesTrend(
      startDate: DateTime(2026, 6, 20),
      endDate: DateTime(2026, 6, 26),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/sales/trend');
    expect(adapter.lastQuery?['bucket'], 'day');
    result.when(
      success: (points) {
        expect(points.first.date, '2026-06-25');
        expect(points.first.amount, 100.5);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('loadSalesTrend maps paged rows from backend response', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"rows":[{"period":"2026-06-26","revenue":230}],"total":1}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadSalesTrend(
      startDate: DateTime(2026, 6, 20),
      endDate: DateTime(2026, 6, 26),
    );

    expect(result.isSuccess, isTrue);
    result.when(
      success: (points) {
        expect(points, hasLength(1));
        expect(points.single.date, '2026-06-26');
        expect(points.single.amount, 230);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('list reports reject success envelope without list payload', () async {
    await _expectMissingListPayload(
      load: (dataSource) => dataSource.loadSalesTrend(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/sales/trend',
      expectedMessage: 'Invalid sales trend response',
    );
    await _expectMissingListPayload(
      load: (dataSource) => dataSource.loadSalesRanking(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/sales/ranking',
      expectedMessage: 'Invalid sales ranking response',
    );
    await _expectMissingListPayload(
      load: (dataSource) => dataSource.loadInventoryTurnover(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/inventory/turnover',
      expectedMessage: 'Invalid inventory turnover response',
    );
    await _expectMissingListPayload(
      load: (dataSource) => dataSource.loadSlowMovingInventory(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/inventory/slow-moving',
      expectedMessage: 'Invalid slow-moving inventory response',
    );
  });

  test('list reports reject success envelope with non-object item', () async {
    await _expectNonObjectListItem(
      load: (dataSource) => dataSource.loadSalesTrend(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/sales/trend',
      expectedMessage: 'Invalid sales trend response',
    );
    await _expectNonObjectListItem(
      load: (dataSource) => dataSource.loadSalesRanking(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/sales/ranking',
      expectedMessage: 'Invalid sales ranking response',
    );
    await _expectNonObjectListItem(
      load: (dataSource) => dataSource.loadInventoryOverview(),
      expectedPath: '/reports/inventory/overview',
      expectedMessage: 'Invalid inventory overview response',
    );
    await _expectNonObjectListItem(
      load: (dataSource) => dataSource.loadInventoryTurnover(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/inventory/turnover',
      expectedMessage: 'Invalid inventory turnover response',
    );
    await _expectNonObjectListItem(
      load: (dataSource) => dataSource.loadSlowMovingInventory(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 26),
      ),
      expectedPath: '/reports/inventory/slow-moving',
      expectedMessage: 'Every paged API list item must be a JSON object.',
    );
  });

  test('loadSalesRanking maps backend revenue field as amount', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"productName":"真实商品","revenue":12345.5,"quantity":7}]}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadSalesRanking(
      startDate: DateTime(2026, 6, 20),
      endDate: DateTime(2026, 6, 26),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/sales/ranking');
    expect(adapter.lastQuery, {
      'startDate': '2026-06-20',
      'endDate': '2026-06-26',
      'metric': 'amount',
      'limit': 5,
    });
    result.when(
      success: (items) {
        expect(items.single.productName, '真实商品');
        expect(items.single.amount, 12345.5);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('loadInventoryOverview maps summary values for home metrics', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"skuCount":12,"totalQty":3456,"lowStockCount":2,"normalStock":10}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadInventoryOverview();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/inventory/overview');
    result.when(
      success: (items) {
        final values = {for (final item in items) item.label: item.value};

        expect(values['商品数'], 12.0);
        expect(values['库存总量'], 3456.0);
        expect(values['预警数量'], 2.0);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'loadInventoryOverview rejects success envelope without payload',
    () async {
      final adapter = _CapturingAdapter(body: '{"code":0,"message":"ok"}');
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiReportsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.loadInventoryOverview();

      expect(result.isFailure, isTrue);
      expect(adapter.lastPath, '/reports/inventory/overview');
      result.when(
        success: (_) => fail('Expected inventory overview payload validation'),
        failure: (failure) =>
            expect(failure.message, 'Invalid inventory overview response'),
      );
    },
  );

  test('loadInventoryTurnover loads turnover endpoint with date range', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"productName":"矿泉水","sku":"SKU-WA","soldQty":20,"avgStockQty":10,"turnoverRate":2.5}]}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadInventoryTurnover(
      startDate: DateTime(2026, 6, 20),
      endDate: DateTime(2026, 6, 26),
      limit: 5,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/inventory/turnover');
    expect(adapter.lastQuery?['startDate'], '2026-06-20');
    expect(adapter.lastQuery?['endDate'], '2026-06-26');
    expect(adapter.lastQuery?['limit'], 5);
    result.when(
      success: (items) {
        expect(items.single.productName, '矿泉水');
        expect(items.single.sku, 'SKU-WA');
        expect(items.single.soldQuantity, 20);
        expect(items.single.averageStockQuantity, 10);
        expect(items.single.turnoverRate, 2.5);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('loadSlowMovingInventory loads slow-moving endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"productName":"纸巾","sku":"SKU-TI","stockQty":80,"salesQty":0,"lastSaleAt":"2026-05-01"}],"total":12,"page":2,"pageSize":5}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiReportsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.loadSlowMovingInventory(
      startDate: DateTime(2026, 6, 20),
      endDate: DateTime(2026, 6, 26),
      maxSales: 1,
      page: 2,
      pageSize: 5,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/reports/inventory/slow-moving');
    expect(adapter.lastQuery?['maxSales'], 1);
    expect(adapter.lastQuery?['page'], 2);
    expect(adapter.lastQuery?['pageSize'], 5);
    result.when(
      success: (page) {
        expect(page.total, 12);
        expect(page.page, 2);
        expect(page.pageSize, 5);
        expect(page.items.single.productName, '纸巾');
        expect(page.items.single.sku, 'SKU-TI');
        expect(page.items.single.stockQuantity, 80);
        expect(page.items.single.salesQuantity, 0);
        expect(page.items.single.lastSaleAt, '2026-05-01');
      },
      failure: (failure) => fail(failure.message),
    );
  });
}

Future<void> _expectMissingListPayload<T>({
  required Future<Result<T>> Function(ApiReportsRemoteDataSource) load,
  required String expectedPath,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(body: '{"code":0,"message":"ok"}');
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiReportsRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
  );

  final result = await load(dataSource);

  expect(result.isFailure, isTrue);
  expect(adapter.lastPath, expectedPath);
  result.when(
    success: (_) => fail('Expected report list payload validation failure'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

Future<void> _expectNonObjectListItem<T>({
  required Future<Result<T>> Function(ApiReportsRemoteDataSource) load,
  required String expectedPath,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(
    body: '{"code":0,"message":"ok","data":{"list":["bad-item"]}}',
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiReportsRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
  );

  final result = await load(dataSource);

  expect(result.isFailure, isTrue);
  expect(adapter.lastPath, expectedPath);
  result.when(
    success: (_) => fail('Expected report list item validation failure'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.body});

  final String body;
  String? lastPath;
  Map<String, dynamic>? lastQuery;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastQuery = options.queryParameters;

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
