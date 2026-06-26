import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';

void main() {
  test('adds bearer authorization header when token is nonempty', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => 'token-123',
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer token-123');
  });

  test('continues without authorization header when token is null', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => null,
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers, isNot(contains('Authorization')));
  });

  test('continues without authorization header when token is empty', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => '',
      adapter: adapter,
    );

    await dio.get<dynamic>('/test');

    expect(adapter.lastOptions?.headers, isNot(contains('Authorization')));
  });

  test('rejects with DioException when token reader throws', () async {
    final adapter = _CapturingAdapter();
    final dio = _dioWithAuthInterceptor(
      tokenReader: () async => throw StateError('token unavailable'),
      adapter: adapter,
    );

    await expectLater(
      dio.get<dynamic>('/test').timeout(const Duration(milliseconds: 250)),
      throwsA(isA<DioException>()),
    );
    expect(adapter.fetchCount, 0);
  });
}

Dio _dioWithAuthInterceptor({
  required TokenReader tokenReader,
  required _CapturingAdapter adapter,
}) {
  return Dio()
    ..httpClientAdapter = adapter
    ..interceptors.add(AuthInterceptor(tokenReader: tokenReader));
}

final class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    lastOptions = options;

    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
