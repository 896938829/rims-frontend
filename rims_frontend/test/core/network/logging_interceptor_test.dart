import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/logging_interceptor.dart';

void main() {
  test('logs safe transfer metadata without secrets or local paths', () async {
    final logs = <String>[];
    final dio = Dio()
      ..interceptors.add(SafeLoggingInterceptor(log: logs.add))
      ..httpClientAdapter = _LoggingAdapter();

    await dio.post<Object>(
      'http://localhost:8080/api/v1/files?token=query-secret',
      data: FormData.fromMap({
        'password': 'hunter2',
        'file': MultipartFile.fromBytes(<int>[
          1,
          2,
          3,
        ], filename: r'C:\private\secret.jpg'),
      }),
      options: Options(headers: {'Authorization': 'Bearer secret-token'}),
    );

    final output = logs.join('\n');
    expect(output, contains('POST'));
    expect(output, contains('/api/v1/files'));
    expect(output, contains('status=201'));
    expect(output, contains('durationMs='));
    expect(output, contains('traceId=trace-safe'));
    expect(output, contains('requestBytes='));
    expect(output, isNot(contains('secret-token')));
    expect(output, isNot(contains('query-secret')));
    expect(output, isNot(contains('hunter2')));
    expect(output, isNot(contains('secret.jpg')));
    expect(output, isNot(contains(r'C:\private')));
  });
}

final class _LoggingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromString(
      '{"code":0,"message":"ok","traceId":"trace-safe"}',
      201,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
