import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';
import 'package:rims_frontend/core/network/interceptors/warehouse_interceptor.dart';

void main() {
  test('attaches logging interceptor by default', () {
    final dio = Dio();

    ApiClient(dio: dio);

    expect(dio.interceptors.whereType<LogInterceptor>(), hasLength(1));
  });

  test('does not attach logging interceptor when logging is disabled', () {
    final dio = Dio();

    ApiClient(dio: dio, enableLogging: false);

    expect(dio.interceptors.whereType<LogInterceptor>(), isEmpty);
  });

  test('attaches auth interceptor when token reader is provided', () {
    final dio = Dio();

    ApiClient(dio: dio, tokenReader: () async => 'token', enableLogging: false);

    expect(dio.interceptors.whereType<AuthInterceptor>(), hasLength(1));
  });

  test('attaches warehouse interceptor when warehouse reader is provided', () {
    final dio = Dio();

    ApiClient(
      dio: dio,
      warehouseIdReader: () async => 12,
      enableLogging: false,
    );

    expect(dio.interceptors.whereType<WarehouseInterceptor>(), hasLength(1));
  });

  test(
    'sends bearer token through requests when token reader is provided',
    () async {
      final adapter = _CapturingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(
        dio: dio,
        tokenReader: () async => 'token',
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/test');

      expect(result.isSuccess, isTrue);
      expect(adapter.lastOptions?.headers['Authorization'], 'Bearer token');
    },
  );

  test(
    'sends warehouse header through requests when reader is provided',
    () async {
      final adapter = _CapturingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = ApiClient(
        dio: dio,
        warehouseIdReader: () async => 12,
        enableLogging: false,
      );

      final result = await client.get<dynamic>('/inventory');

      expect(result.isSuccess, isTrue);
      expect(adapter.lastOptions?.headers['X-Warehouse-ID'], '12');
    },
  );
}

final class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;

    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
