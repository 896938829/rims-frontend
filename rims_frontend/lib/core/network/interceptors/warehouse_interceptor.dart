import 'dart:async';

import 'package:dio/dio.dart';

typedef WarehouseIdReader = Future<int?> Function();

final class WarehouseInterceptor extends Interceptor {
  const WarehouseInterceptor({required this.warehouseIdReader});

  final WarehouseIdReader warehouseIdReader;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    unawaited(_handleRequest(options, handler));
  }

  Future<void> _handleRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final warehouseId = await warehouseIdReader();
      if (warehouseId != null) {
        options.headers['X-Warehouse-ID'] = warehouseId.toString();
      }

      handler.next(options);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }
}
