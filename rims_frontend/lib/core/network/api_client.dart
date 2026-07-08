import 'package:dio/dio.dart';

import '../events/app_event.dart';
import '../events/app_event_bus.dart';
import '../result/failure.dart';
import '../result/result.dart';
import 'api_endpoints.dart';
import 'api_exception_mapper.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/logging_interceptor.dart';
import 'interceptors/warehouse_interceptor.dart';

final class ApiClient {
  ApiClient({
    Dio? dio,
    ApiExceptionMapper exceptionMapper = const ApiExceptionMapper(),
    TokenReader? tokenReader,
    WarehouseIdReader? warehouseIdReader,
    AppEventBus? eventBus,
    bool enableLogging = true,
  }) : this._(
         dio: dio ?? Dio(),
         exceptionMapper: exceptionMapper,
         tokenReader: tokenReader,
         warehouseIdReader: warehouseIdReader,
         eventBus: eventBus,
         enableLogging: enableLogging,
       );

  ApiClient._({
    required this._dio,
    required this._exceptionMapper,
    required TokenReader? tokenReader,
    required WarehouseIdReader? warehouseIdReader,
    required this.eventBus,
    required bool enableLogging,
  }) {
    _dio.options = BaseOptions(
      baseUrl: ApiEndpoints.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    );

    if (enableLogging) {
      _dio.interceptors.add(buildLoggingInterceptor());
    }

    if (tokenReader != null) {
      _dio.interceptors.add(AuthInterceptor(tokenReader: tokenReader));
    }

    if (warehouseIdReader != null) {
      _dio.interceptors.add(
        WarehouseInterceptor(warehouseIdReader: warehouseIdReader),
      );
    }
  }

  final Dio _dio;
  final ApiExceptionMapper _exceptionMapper;
  final AppEventBus? eventBus;

  Dio get dio => _dio;

  Future<Result<Response<T>>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      path,
      () =>
          _dio.get<T>(path, queryParameters: queryParameters, options: options),
    );
  }

  Future<Result<Response<T>>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      path,
      () => _dio.post<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      path,
      () => _dio.put<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      path,
      () => _dio.patch<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) {
    return _request(
      path,
      () => _dio.delete<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
      ),
    );
  }

  Future<Result<Response<T>>> _request<T>(
    String path,
    Future<Response<T>> Function() request,
  ) async {
    try {
      return Success<Response<T>>(await request());
    } catch (error) {
      final failure = _exceptionMapper.map(error);
      if (failure is AuthenticationFailure && _publishesTokenExpired(path)) {
        eventBus?.publish(const TokenExpiredEvent());
      }
      return FailureResult<Response<T>>(failure);
    }
  }

  bool _publishesTokenExpired(String path) {
    return path != ApiEndpoints.login;
  }
}
