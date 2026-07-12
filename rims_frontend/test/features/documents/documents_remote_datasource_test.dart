import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/features/documents/data/datasources/documents_remote_datasource.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';

void main() {
  test('getDocument loads authoritative header and all lines', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":42,"docNo":"RK20260713001","docType":1,"docTypeName":"入库单","statusName":"草稿","lines":[{"id":101,"productId":7,"productCode":"SKU-7","productName":"矿泉水","quantity":3,"unit":"箱","remark":""}]}}',
    );
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: Dio()..httpClientAdapter = adapter, enableLogging: false),
    );

    final result = await dataSource.getDocument(42);

    expect(adapter.lastPath, '/documents/42');
    result.when(
      success: (detail) => expect(detail.lines.single.id, 101),
      failure: (failure) => fail(failure.message),
    );
  });

  test('getDocument rejects success without a lines array', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":42,"docNo":"RK20260713001","docType":1,"docTypeName":"入库单","statusName":"草稿"}}',
    );
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: Dio()..httpClientAdapter = adapter, enableLogging: false),
    );

    expect((await dataSource.getDocument(42)).isFailure, isTrue);
  });

  test('listRecentDocuments uses backend pageSize query parameter', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":7,"docNo":"XS-20260627-001","docType":2,"docTypeName":"销售单","statusName":"待提交"}],"total":21,"page":1,"pageSize":10}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listRecentDocuments();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/documents');
    expect(adapter.lastQueryParameters, {'page': 1, 'pageSize': 10});
    result.when(
      success: (page) {
        expect(page.items.single.id, 7);
        expect(page.total, 21);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('listRecentDocuments sends selected document type parameter', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":7,"docNo":"XS-20260627-001","docType":2,"docTypeName":"销售单","statusName":"待提交"}],"total":21,"page":3,"pageSize":10}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listRecentDocuments(docType: 2, page: 3);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/documents');
    expect(adapter.lastQueryParameters, {
      'page': 3,
      'pageSize': 10,
      'docType': 2,
    });
    result.when(
      success: (page) {
        expect(page.page, 3);
        expect(page.pageSize, 10);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'listRecentDocuments rejects success envelope without list payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listRecentDocuments();

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('listRecentDocuments should fail without backend list data'),
        failure: (failure) =>
            expect(failure.message, 'Paged API data.list must be a JSON list.'),
      );
    },
  );

  test(
    'listRecentDocuments rejects success envelope with non-object list item',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"list":["bad-item"],"total":1,"page":1,"pageSize":10}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listRecentDocuments();

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('listRecentDocuments should fail with malformed list item'),
        failure: (failure) => expect(
          failure.message,
          'Every paged API list item must be a JSON object.',
        ),
      );
    },
  );

  test('createDocument sends backend-compatible document payload', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createDocument(
      const CreateDocumentRequest(
        docType: 2,
        typeLabel: '销售出库',
        productId: 10,
        productName: '矿泉水 550ml',
        quantity: 3,
        retailPrice: 6.5,
        remark: 'M9-E2E:run-42:sales',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/documents');
    expect(adapter.lastData, {
      'docType': 2,
      'remark': 'M9-E2E:run-42:sales',
      'lines': [
        {'productId': 10, 'quantity': 3, 'retailPrice': 6.5},
      ],
    });
  });

  test(
    'createDocument sends all typed lines with one stable request ID',
    () async {
      final adapter = _CapturingAdapter();
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(
          dio: Dio()..httpClientAdapter = adapter,
          enableLogging: false,
        ),
      );

      await dataSource.createDocument(
        const CreateDocumentRequest(
          docType: 2,
          typeLabel: '销售出库',
          requestId: 'document-request-1',
          lines: [
            CreateDocumentLineRequest(
              productId: 10,
              productName: '矿泉水',
              quantity: 2,
              retailPrice: 6.5,
            ),
            CreateDocumentLineRequest(
              productId: 11,
              productName: '纸巾',
              quantity: 3,
              retailPrice: 12,
            ),
          ],
        ),
      );

      expect(adapter.lastIdempotencyKey, 'document-request-1');
      expect((adapter.lastData as Map<String, Object?>)['lines'], [
        {'productId': 10, 'quantity': 2, 'retailPrice': 6.5},
        {'productId': 11, 'quantity': 3, 'retailPrice': 12.0},
      ]);
    },
  );

  test(
    'createDocument rejects success envelope without document payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createDocument(
        const CreateDocumentRequest(
          docType: 2,
          typeLabel: '销售出库',
          productId: 10,
          productName: '矿泉水 550ml',
          quantity: 3,
        ),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('createDocument should fail without backend document data'),
        failure: (failure) =>
            expect(failure.message, 'Invalid document response'),
      );
    },
  );

  test(
    'createDocument includes target warehouse for transfer payload',
    () async {
      final adapter = _CapturingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createDocument(
        const CreateDocumentRequest(
          docType: 4,
          typeLabel: '调拨单',
          productId: 10,
          productName: '矿泉水 550ml',
          quantity: 3,
          toWarehouseId: 2,
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.lastData, {
        'docType': 4,
        'toWarehouseId': 2,
        'lines': [
          {'productId': 10, 'quantity': 3},
        ],
      });
    },
  );

  test('createDocument includes source document for return payload', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createDocument(
      const CreateDocumentRequest(
        docType: 3,
        typeLabel: '退货入库',
        productId: 10,
        productName: '矿泉水 550ml',
        quantity: 1,
        refDocId: 136,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastData, {
      'docType': 3,
      'refDocId': 136,
      'lines': [
        {'productId': 10, 'quantity': 1},
      ],
    });
  });

  test('createDocument sends actual quantity for stocktake payload', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createDocument(
      const CreateDocumentRequest(
        docType: 5,
        typeLabel: '盘点单',
        productId: 10,
        productName: '矿泉水 550ml',
        quantity: 0,
        actualQuantity: 8,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastData, {
      'docType': 5,
      'lines': [
        {'productId': 10, 'actualQty': 8},
      ],
    });
  });

  test('createDocument sends non-standard conversion payload', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createDocument(
      const CreateDocumentRequest(
        docType: 6,
        typeLabel: '转标准',
        productId: 10,
        productName: '矿泉水 550ml',
        quantity: 2,
        nonStdInventoryId: 11,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastData, {
      'docType': 6,
      'lines': [
        {'nonStdInvId': 11, 'productId': 10, 'quantity': 2},
      ],
    });
  });

  test(
    'completeDocument posts complete endpoint and accepts empty success',
    () async {
      final adapter = _CapturingAdapter(statusCode: 204, body: '');
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.completeDocument(7);

      expect(result.isSuccess, isTrue);
      expect(adapter.lastPath, '/documents/7/complete');
      expect(adapter.lastData, isNull);
    },
  );

  test('confirmDocument posts stocktake confirm endpoint', () async {
    final adapter = _CapturingAdapter(statusCode: 204, body: '');
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.confirmDocument(7);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/documents/7/confirm');
    expect(adapter.lastData, isNull);
  });

  test('settleDocument posts stocktake settle endpoint', () async {
    final adapter = _CapturingAdapter(statusCode: 204, body: '');
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.settleDocument(7);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/documents/7/settle');
    expect(adapter.lastData, isNull);
  });

  test('listTransactions loads inventory transaction endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":21,"warehouseId":1,"productId":10,"docId":7,"docNo":"XS20260627001","docType":2,"docTypeName":"销售单","direction":-1,"quantity":3,"beforeQty":12,"afterQty":9,"operatorId":5,"operatedAt":"2026-06-27T10:30:00Z","createdAt":"2026-06-27T10:30:00Z"}],"total":1,"page":1,"pageSize":10}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiDocumentsRemoteDataSource(
      ApiClient(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listTransactions(keyword: 'XS2026');

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/transactions');
    expect(adapter.lastQueryParameters, {
      'page': 1,
      'pageSize': 10,
      'keyword': 'XS2026',
    });
    result.when(
      success: (page) {
        expect(page.items.single.id, 21);
        expect(page.items.single.docNo, 'XS20260627001');
        expect(page.items.single.direction, -1);
        expect(page.total, 1);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'listTransactions rejects success envelope without list payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listTransactions();

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('listTransactions should fail without backend list data'),
        failure: (failure) =>
            expect(failure.message, 'Paged API data.list must be a JSON list.'),
      );
    },
  );

  test(
    'listTransactions rejects success envelope with non-object list item',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"list":["bad-item"],"total":1,"page":1,"pageSize":10}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiDocumentsRemoteDataSource(
        ApiClient(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listTransactions();

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('listTransactions should fail with malformed list item'),
        failure: (failure) => expect(
          failure.message,
          'Every paged API list item must be a JSON object.',
        ),
      );
    },
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({
    this.statusCode = 200,
    this.body =
        '{"code":0,"message":"ok","data":{"id":7,"docNo":"XS-20260627-001","docTypeName":"销售单","statusName":"待提交"}}',
  });

  final int statusCode;
  final String body;
  Object? lastData;
  String? lastPath;
  Map<String, dynamic>? lastQueryParameters;
  String? lastIdempotencyKey;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastData = options.data;
    lastQueryParameters = options.queryParameters;
    lastIdempotencyKey = options.headers['Idempotency-Key']?.toString();

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
