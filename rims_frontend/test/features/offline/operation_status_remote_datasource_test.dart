import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';

void main() {
  test('queries URL-safe idempotency key with route-template scope', () async {
    final adapter = _StatusAdapter(
      body:
          '{"code":0,"message":"ok","data":{"state":"processing","status_code":0,"expires_at":"2026-07-14T01:02:03Z"}}',
    );
    final dataSource = _dataSource(adapter);

    final result = await dataSource.loadStatus(
      key: 'AZaz09._~-',
      scope: 'POST /api/v1/documents/:id/complete',
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastPath, '/operations/idempotency/AZaz09._~-');
    expect(adapter.lastQuery?['scope'], 'POST /api/v1/documents/:id/complete');
    expect(
      adapter.lastUri?.queryParameters['scope'],
      'POST /api/v1/documents/:id/complete',
    );
  });

  for (final testCase in <({String name, String key})>[
    (name: 'empty', key: ''),
    (name: 'unicode', key: '幂等键'),
    (name: 'slash', key: 'draft/key'),
    (name: 'too long', key: List.filled(256, 'a').join()),
  ]) {
    test(
      'rejects invalid idempotency key before request: ${testCase.name}',
      () async {
        final adapter = _StatusAdapter(
          body:
              '{"code":0,"message":"ok","data":{"state":"processing","status_code":0,"expires_at":"2026-07-14T01:02:03Z"}}',
        );
        final dataSource = _dataSource(adapter);

        final result = await dataSource.loadStatus(
          key: testCase.key,
          scope: 'POST /api/v1/documents',
        );

        result.when(
          success: (_) => fail('Expected validation failure'),
          failure: (failure) => expect(failure, isA<ValidationFailure>()),
        );
        expect(adapter.lastPath, isNull);
      },
    );
  }

  for (final key in <String>[List.filled(255, 'a').join(), 'AZaz09._~-']) {
    test('accepts valid boundary idempotency key: ${key.length}', () async {
      final adapter = _StatusAdapter(
        body:
            '{"code":0,"message":"ok","data":{"state":"processing","status_code":0,"expires_at":"2026-07-14T01:02:03Z"}}',
      );
      final dataSource = _dataSource(adapter);

      final result = await dataSource.loadStatus(
        key: key,
        scope: 'POST /api/v1/documents',
      );

      expect(result.isSuccess, isTrue);
      expect(
        adapter.lastPath,
        '/operations/idempotency/${Uri.encodeComponent(key)}',
      );
    });
  }

  test('parses immutable processing operation status', () async {
    final dataSource = _dataSource(
      _StatusAdapter(
        body:
            '{"code":0,"message":"ok","data":{"state":"processing","status_code":0,"expires_at":"2026-07-14T01:02:03Z"}}',
      ),
    );

    final result = await dataSource.loadStatus(
      key: 'key-1',
      scope: 'POST /api/v1/documents',
    );

    result.when(
      success: (status) {
        expect(status.state, OperationState.processing);
        expect(status.statusCode, 0);
        expect(status.expiresAt, DateTime.utc(2026, 7, 14, 1, 2, 3));
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('parses immutable completed operation status', () async {
    final dataSource = _dataSource(
      _StatusAdapter(
        body:
            '{"code":0,"message":"ok","data":{"state":"completed","status_code":201,"expires_at":"2026-07-14T01:02:03Z"}}',
      ),
    );

    final result = await dataSource.loadStatus(
      key: 'key-1',
      scope: 'POST /api/v1/documents',
    );

    result.when(
      success: (status) {
        expect(status.state, OperationState.completed);
        expect(status.statusCode, 201);
        expect(status.expiresAt, DateTime.utc(2026, 7, 14, 1, 2, 3));
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('preserves NotFoundFailure for absent or expired operation', () async {
    final dataSource = _dataSource(
      _StatusAdapter(
        statusCode: 404,
        body: '{"code":10004,"message":"idempotency operation not found"}',
      ),
    );

    final result = await dataSource.loadStatus(
      key: 'missing',
      scope: 'POST /api/v1/documents',
    );

    result.when(
      success: (_) => fail('Expected not found failure'),
      failure: (failure) {
        expect(failure, isA<NotFoundFailure>());
        expect(failure.message, 'idempotency operation not found');
        expect(failure.statusCode, 404);
      },
    );
  });

  test('preserves other ApiClient failures', () async {
    final dataSource = _dataSource(
      _StatusAdapter(
        statusCode: 503,
        body: '{"code":50000,"message":"temporarily unavailable"}',
      ),
    );

    final result = await dataSource.loadStatus(
      key: 'key-1',
      scope: 'POST /api/v1/documents',
    );

    result.when(
      success: (_) => fail('Expected server failure'),
      failure: (failure) {
        expect(failure, isA<ServerFailure>());
        expect(failure.message, 'temporarily unavailable');
        expect(failure.statusCode, 503);
      },
    );
  });

  for (final testCase in <({String name, String data})>[
    (name: 'non-object data', data: 'null'),
    (
      name: 'unknown state',
      data:
          '{"state":"unknown","status_code":200,"expires_at":"2026-07-14T01:02:03Z"}',
    ),
    (
      name: 'missing status code',
      data: '{"state":"completed","expires_at":"2026-07-14T01:02:03Z"}',
    ),
    (
      name: 'non-integer status code',
      data:
          '{"state":"completed","status_code":"201","expires_at":"2026-07-14T01:02:03Z"}',
    ),
    (name: 'missing expiry', data: '{"state":"processing","status_code":0}'),
    (
      name: 'malformed expiry',
      data: '{"state":"processing","status_code":0,"expires_at":"not-a-date"}',
    ),
    (
      name: 'unexpected sensitive field',
      data:
          '{"state":"completed","status_code":201,"expires_at":"2026-07-14T01:02:03Z","response_body":{"secret":true}}',
    ),
  ]) {
    test('rejects malformed success payload: ${testCase.name}', () async {
      final dataSource = _dataSource(
        _StatusAdapter(
          body: '{"code":0,"message":"ok","data":${testCase.data}}',
        ),
      );

      final result = await dataSource.loadStatus(
        key: 'key-1',
        scope: 'POST /api/v1/documents',
      );

      result.when(
        success: (_) => fail('Expected malformed payload failure'),
        failure: (failure) {
          expect(failure, isA<UnknownFailure>());
          expect(
            failure.message,
            'Invalid idempotency operation status response',
          );
        },
      );
    });
  }
}

ApiOperationStatusRemoteDataSource _dataSource(_StatusAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiOperationStatusRemoteDataSource(
    ApiClient(dio: dio, enableLogging: false),
  );
}

final class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter({required this.body, this.statusCode = 200});

  final String body;
  final int statusCode;
  String? lastPath;
  Map<String, dynamic>? lastQuery;
  Uri? lastUri;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastQuery = Map<String, dynamic>.from(options.queryParameters);
    lastUri = options.uri;
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
