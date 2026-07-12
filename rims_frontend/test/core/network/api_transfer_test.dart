import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/failure.dart';

void main() {
  test('forwards cancellation and upload/download progress', () async {
    final adapter = _TransferAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = ApiClient(dio: dio, enableLogging: false);
    final cancelToken = CancelToken();
    final sent = <String>[];
    final received = <String>[];

    final result = await client.post<List<int>>(
      '/files',
      data: Uint8List.fromList([1, 2, 3]),
      cancelToken: cancelToken,
      onSendProgress: (count, total) => sent.add('$count/$total'),
      onReceiveProgress: (count, total) => received.add('$count/$total'),
      options: Options(responseType: ResponseType.bytes),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.cancelFuture, isNotNull);
    expect(sent, isNotEmpty);
    expect(received, isNotEmpty);
    result.when(
      success: (response) => expect(response.data, <int>[4, 5, 6]),
      failure: (failure) => fail(failure.message),
    );
  });

  test('cancelled request returns CancellationFailure', () async {
    final token = CancelToken()..cancel('user cancelled');
    final client = ApiClient(dio: Dio(), enableLogging: false);

    final result = await client.get<Object>('/slow', cancelToken: token);

    result.when(
      success: (_) => fail('cancelled request should fail'),
      failure: (failure) => expect(failure, isA<CancellationFailure>()),
    );
  });

  test('declares device, local storage, and attachment failures', () {
    expect(
      const DevicePermissionFailure(message: 'camera denied'),
      isA<Failure>(),
    );
    expect(const LocalStorageFailure(message: 'disk full'), isA<Failure>());
    expect(const AttachmentFailure(message: 'invalid file'), isA<Failure>());
  });
}

final class _TransferAdapter implements HttpClientAdapter {
  Future<void>? cancelFuture;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    this.cancelFuture = cancelFuture;
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromBytes(<int>[4, 5, 6], 200);
  }

  @override
  void close({bool force = false}) {}
}
