import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../config/app_environment.dart';
import '../events/app_event.dart';
import '../events/app_event_bus.dart';
import '../result/failure.dart';
import '../result/result.dart';
import 'api_endpoints.dart';
import 'api_exception_mapper.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/logging_interceptor.dart';
import 'interceptors/warehouse_interceptor.dart';

typedef ApiRequestObserver = void Function(ApiRequestOutcome outcome);

final class ApiRequestOutcome {
  const ApiRequestOutcome({
    required this.path,
    required this.succeeded,
    this.failure,
  });

  final String path;
  final bool succeeded;
  final Failure? failure;
}

final class ApiClient {
  ApiClient({
    required AppConfiguration configuration,
    Dio? dio,
    ApiExceptionMapper exceptionMapper = const ApiExceptionMapper(),
    TokenReader? tokenReader,
    WarehouseIdReader? warehouseIdReader,
    AppEventBus? eventBus,
    ApiRequestObserver? requestObserver,
    bool enableLogging = true,
  }) : this._(
         dio: dio ?? Dio(),
         exceptionMapper: exceptionMapper,
         tokenReader: tokenReader,
         warehouseIdReader: warehouseIdReader,
         eventBus: eventBus,
         requestObserver: requestObserver,
         enableLogging: enableLogging,
         apiBaseUri: configuration.apiBaseUri,
       );

  @visibleForTesting
  ApiClient.test({
    Dio? dio,
    ApiExceptionMapper exceptionMapper = const ApiExceptionMapper(),
    TokenReader? tokenReader,
    WarehouseIdReader? warehouseIdReader,
    AppEventBus? eventBus,
    ApiRequestObserver? requestObserver,
    bool enableLogging = true,
  }) : this._(
         dio: dio ?? Dio(),
         exceptionMapper: exceptionMapper,
         tokenReader: tokenReader,
         warehouseIdReader: warehouseIdReader,
         eventBus: eventBus,
         requestObserver: requestObserver,
         enableLogging: enableLogging,
         apiBaseUri: AppConfiguration.localTest().apiBaseUri,
       );

  ApiClient._({
    required this._dio,
    required this._exceptionMapper,
    required TokenReader? tokenReader,
    required WarehouseIdReader? warehouseIdReader,
    required this.eventBus,
    required this.requestObserver,
    required bool enableLogging,
    required Uri apiBaseUri,
  }) : _tokenReader = tokenReader {
    _dio.options = BaseOptions(
      baseUrl: apiBaseUri.toString(),
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
  final TokenReader? _tokenReader;
  final AppEventBus? eventBus;
  final ApiRequestObserver? requestObserver;

  Dio get dio => _dio;

  Future<Result<Response<T>>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) {
    return _request(
      path,
      () => _dio.get<T>(
        path,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      ),
    );
  }

  Future<Result<Response<T>>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _request(
      path,
      () => _dio.post<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      ),
    );
  }

  Future<Result<Response<T>>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _request(
      path,
      () => _dio.put<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      ),
    );
  }

  Future<Result<Response<T>>> patch<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _request(
      path,
      () => _dio.patch<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      ),
    );
  }

  Future<Result<Response<T>>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _request(
      path,
      () => _dio.delete<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<Result<Response<T>>> _request<T>(
    String path,
    Future<Response<T>> Function() request,
  ) async {
    try {
      final response = await request();
      _observe(ApiRequestOutcome(path: path, succeeded: true));
      return Success<Response<T>>(response);
    } catch (error) {
      final failure = _exceptionMapper.map(error);
      _observe(
        ApiRequestOutcome(path: path, succeeded: false, failure: failure),
      );
      if (failure is AuthenticationFailure &&
          await _shouldPublishTokenExpired(path, error)) {
        eventBus?.publish(const TokenExpiredEvent());
      }
      return FailureResult<Response<T>>(failure);
    }
  }

  bool _publishesTokenExpired(String path) {
    return path != ApiEndpoints.login;
  }

  Future<bool> _shouldPublishTokenExpired(String path, Object error) async {
    if (!_publishesTokenExpired(path)) return false;
    final tokenReader = _tokenReader;
    if (tokenReader == null) return true;
    final requestToken = _requestBearerToken(error);
    if (requestToken == null) return true;
    try {
      return await tokenReader() == requestToken;
    } on Object {
      return true;
    }
  }

  String? _requestBearerToken(Object error) {
    if (error is! DioException) return null;
    Object? authorization;
    for (final entry in error.requestOptions.headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        authorization = entry.value;
        break;
      }
    }
    if (authorization is! String || !authorization.startsWith('Bearer ')) {
      return null;
    }
    final token = authorization.substring('Bearer '.length);
    return token.isEmpty ? null : token;
  }

  void _observe(ApiRequestOutcome outcome) {
    try {
      requestObserver?.call(outcome);
    } on Object {
      // Observation must never alter the request result.
    }
  }
}
