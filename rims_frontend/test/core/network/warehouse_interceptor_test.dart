import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/warehouse_interceptor.dart';

void main() {
  test('adds X-Warehouse-ID when a warehouse id is available', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(
        WarehouseInterceptor(warehouseIdReader: () async => 12),
      );

    await dio.get<dynamic>('/inventory');

    expect(adapter.lastOptions?.headers['X-Warehouse-ID'], '12');
  });

  test('continues without X-Warehouse-ID when no warehouse is selected', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(
        WarehouseInterceptor(warehouseIdReader: () async => null),
      );

    await dio.get<dynamic>('/products');

    expect(adapter.lastOptions?.headers, isNot(contains('X-Warehouse-ID')));
  });
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
