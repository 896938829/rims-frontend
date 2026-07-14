import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';

void main() {
  late Directory temp;
  late File source;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rims_attachment_test_');
    source = File('${temp.path}${Platform.pathSeparator}receipt.pdf');
    await source.writeAsBytes(List<int>.generate(128, (index) => index));
  });

  tearDown(() => temp.delete(recursive: true));

  test('maps a business authorization envelope before presentation', () async {
    final adapter = _AttachmentAdapter(
      jsonBody: '{"code":10002,"message":"warehouse denied","data":null}',
    );

    final result = await _dataSource(
      adapter,
    ).list(binding: AttachmentBinding.document(42));

    result.when(
      success: (_) => fail('authorization envelope must fail'),
      failure: (failure) {
        expect(failure, isA<AuthorizationFailure>());
        expect(failure.businessCode, 10002);
      },
    );
  });

  test('lists a bound page with strict paging fields', () async {
    final adapter = _AttachmentAdapter(jsonBody: _pageBody);
    final dataSource = _dataSource(adapter);

    final result = await dataSource.list(
      binding: AttachmentBinding.document(42),
      page: 2,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.path, '/files');
    expect(adapter.query, {
      'businessType': 'doc_attachment',
      'businessId': 42,
      'page': 2,
      'pageSize': 20,
    });
  });

  test('rejects a malformed success envelope page', () async {
    final adapter = _AttachmentAdapter(
      jsonBody: '{"code":0,"message":"ok","data":{"list":[]}}',
    );
    final result = await _dataSource(
      adapter,
    ).list(binding: AttachmentBinding.document(42));

    expect(result.isFailure, isTrue);
  });

  test(
    'upload sends multipart binding, stable idempotency key, and progress',
    () async {
      final adapter = _AttachmentAdapter(jsonBody: _itemBody);
      final progress = <(int, int)>[];
      final pending = PendingAttachment(
        requestId: 'request-stable-1',
        binding: AttachmentBinding.document(42),
        stagedPath: source.path,
        originalName: 'receipt.pdf',
        mimeType: 'application/pdf',
        fileSize: 128,
      );

      final result = await _dataSource(adapter).upload(
        pending,
        onProgress: (sent, total) => progress.add((sent, total)),
        cancellation: TransferCancellation(),
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.path, '/files/upload');
      expect(adapter.idempotencyKey, 'request-stable-1');
      expect(adapter.multipartFields['businessType'], 'doc_attachment');
      expect(adapter.multipartFields['businessId'], '42');
      expect(adapter.multipartFilename, 'receipt.pdf');
      expect(progress, isNotEmpty);
    },
  );

  test(
    'snapshot upload sends supplied bytes after the staged path is gone',
    () async {
      final adapter = _AttachmentAdapter(jsonBody: _itemBody);
      final pending = PendingAttachment(
        requestId: 'request-snapshot-1',
        binding: AttachmentBinding.document(42),
        stagedPath: source.path,
        originalName: 'receipt.pdf',
        mimeType: 'application/pdf',
        fileSize: 4,
      );
      await source.delete();

      final result = await _dataSource(adapter).uploadBytes(
        pending,
        bytes: const [251, 252, 253, 254],
        onProgress: (_, _) {},
        cancellation: TransferCancellation(),
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.idempotencyKey, 'request-snapshot-1');
      expect(
        _containsBytes(adapter.multipartBody, const [251, 252, 253, 254]),
        isTrue,
      );
    },
  );

  test(
    'replace preserves request id and sends only the replacement file',
    () async {
      final adapter = _AttachmentAdapter(jsonBody: _itemBody);
      final pending = PendingAttachment(
        requestId: 'replace-stable-1',
        binding: AttachmentBinding.document(42),
        stagedPath: source.path,
        originalName: 'new.pdf',
        mimeType: 'application/pdf',
        fileSize: 128,
      );

      final result = await _dataSource(adapter).replace(
        7,
        pending,
        onProgress: (_, _) {},
        cancellation: TransferCancellation(),
      );

      expect(result.isSuccess, isTrue);
      expect(adapter.path, '/files/7/replace');
      expect(adapter.idempotencyKey, 'replace-stable-1');
      expect(adapter.multipartFields, isEmpty);
      expect(adapter.multipartFilename, 'new.pdf');
    },
  );

  test('pre-cancelled upload returns cancellation without a request', () async {
    final adapter = _AttachmentAdapter(jsonBody: _itemBody);
    final cancellation = TransferCancellation()..cancel();
    final pending = PendingAttachment(
      requestId: 'cancelled',
      binding: AttachmentBinding.document(42),
      stagedPath: source.path,
      originalName: 'receipt.pdf',
      mimeType: 'application/pdf',
      fileSize: 128,
    );

    final result = await _dataSource(
      adapter,
    ).upload(pending, onProgress: (_, _) {}, cancellation: cancellation);

    expect(result.isFailure, isTrue);
    expect(adapter.requests, 0);
  });

  test('cancels an upload already handed to Dio', () async {
    final adapter = _AttachmentAdapter(jsonBody: _itemBody)
      ..waitForCancellation = true;
    final cancellation = TransferCancellation();
    final pending = PendingAttachment(
      requestId: 'cancel-in-flight',
      binding: AttachmentBinding.document(42),
      stagedPath: source.path,
      originalName: 'receipt.pdf',
      mimeType: 'application/pdf',
      fileSize: 128,
    );

    final transfer = _dataSource(
      adapter,
    ).upload(pending, onProgress: (_, _) {}, cancellation: cancellation);
    await adapter.started.future;
    cancellation.cancel();
    final result = await transfer;

    expect(result.isFailure, isTrue);
    result.when(
      success: (_) => fail('expected cancellation'),
      failure: (failure) =>
          expect(failure.runtimeType.toString(), 'CancellationFailure'),
    );
  });

  test('reorders, downloads authorized bytes, and deletes', () async {
    final adapter = _AttachmentAdapter(jsonBody: _itemBody);
    final dataSource = _dataSource(adapter);

    adapter.jsonBody = jsonEncode({
      'code': 0,
      'message': 'ok',
      'data': [_item],
    });
    final reorder = await dataSource.reorder(AttachmentBinding.document(42), [
      7,
      8,
    ]);
    expect(reorder.isSuccess, isTrue);
    expect(adapter.path, '/files/reorder');
    expect(adapter.jsonData, {
      'businessType': 'doc_attachment',
      'businessId': 42,
      'fileIds': [7, 8],
    });

    adapter.binaryBody = Uint8List.fromList([1, 2, 3]);
    final download = await dataSource.download(7);
    expect(download.isSuccess, isTrue);
    expect(adapter.path, '/files/7/download');
    download.when(
      success: (bytes) => expect(bytes, [1, 2, 3]),
      failure: (failure) => fail(failure.message),
    );

    adapter.statusCode = 204;
    final delete = await dataSource.delete(7);
    expect(delete.isSuccess, isTrue);
    expect(adapter.path, '/files/7');
  });
}

ApiAttachmentsRemoteDataSource _dataSource(_AttachmentAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiAttachmentsRemoteDataSource(
    ApiClient.test(dio: dio, enableLogging: false),
  );
}

const _item = <String, Object?>{
  'id': 7,
  'businessType': 'doc_attachment',
  'businessId': 42,
  'fileUrl': '/api/v1/files/7/download',
  'originalName': 'receipt.pdf',
  'fileSize': 128,
  'mimeType': 'application/pdf',
  'fileHash': 'abc123',
  'isPublic': false,
  'createdBy': 3,
  'uploadedAt': '2026-07-13T08:30:00Z',
  'position': 0,
};
final _itemBody = jsonEncode({'code': 0, 'message': 'ok', 'data': _item});
final _pageBody = jsonEncode({
  'code': 0,
  'message': 'ok',
  'data': {
    'list': [_item],
    'total': 21,
    'page': 2,
    'pageSize': 20,
  },
});

final class _AttachmentAdapter implements HttpClientAdapter {
  _AttachmentAdapter({required this.jsonBody});

  String jsonBody;
  Uint8List? binaryBody;
  int statusCode = 200;
  bool waitForCancellation = false;
  final Completer<void> started = Completer<void>();
  int requests = 0;
  String? path;
  Map<String, dynamic>? query;
  String? idempotencyKey;
  Map<String, Object?>? jsonData;
  final Map<String, String> multipartFields = {};
  String? multipartFilename;
  List<int> multipartBody = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (!started.isCompleted) started.complete();
    path = options.path;
    query = options.queryParameters;
    idempotencyKey = options.headers['Idempotency-Key']?.toString();
    if (options.data is Map<String, Object?>) {
      jsonData = options.data as Map<String, Object?>;
    }
    if (options.data is FormData) {
      final form = options.data as FormData;
      multipartFields
        ..clear()
        ..addEntries(form.fields);
      multipartFilename = form.files.single.value.filename;
    }
    if (requestStream != null) {
      multipartBody = await requestStream.expand((chunk) => chunk).toList();
    }
    if (waitForCancellation && cancelFuture != null) {
      await cancelFuture;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'cancelled by test',
      );
    }
    final bytes = binaryBody ?? Uint8List.fromList(utf8.encode(jsonBody));
    return ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [
          binaryBody == null
              ? Headers.jsonContentType
              : 'application/octet-stream',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

bool _containsBytes(List<int> source, List<int> expected) {
  for (var start = 0; start <= source.length - expected.length; start += 1) {
    var matches = true;
    for (var offset = 0; offset < expected.length; offset += 1) {
      if (source[start + offset] != expected[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
