import 'dart:async';

import 'package:dio/dio.dart';

typedef TokenReader = Future<String?> Function();

final class AuthInterceptor extends Interceptor {
  const AuthInterceptor({required TokenReader tokenReader})
    : this._(tokenReader);

  const AuthInterceptor._(this._tokenReader);

  final TokenReader _tokenReader;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    unawaited(_handleRequest(options, handler));
  }

  Future<void> _handleRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (options.headers.containsKey('Authorization')) {
        handler.next(options);
        return;
      }
      final token = await _tokenReader();

      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
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
