// ignore_for_file: prefer_initializing_formals

import 'package:dio/dio.dart';

typedef TokenReader = Future<String?> Function();

final class AuthInterceptor extends Interceptor {
  const AuthInterceptor({required TokenReader tokenReader})
    : _tokenReader = tokenReader;

  final TokenReader _tokenReader;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokenReader();

    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    handler.next(options);
  }
}
