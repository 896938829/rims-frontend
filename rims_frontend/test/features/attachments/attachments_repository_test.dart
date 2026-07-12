import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'package:rims_frontend/features/attachments/data/models/attachment_models.dart';
import 'package:rims_frontend/features/attachments/data/repositories/attachments_repository_impl.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';

void main() {
  test('maps list models to immutable attachment entities', () async {
    final remote = _FakeRemote()..listResult = Success(_modelPage());
    final repository = AttachmentsRepositoryImpl(
      remoteDataSource: remote,
      apiBaseUri: Uri.parse('http://localhost:8080/api/v1'),
      saveDownload: (_, bytes) async => '/support/receipt.pdf',
    );

    final result = await repository.list(
      binding: AttachmentBinding.document(42),
    );

    result.when(
      success: (page) {
        expect(page.items.single.id, 7);
        expect(page.items.single.downloadUri.host, 'localhost');
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'writes authenticated downloaded bytes through injected storage',
    () async {
      final remote = _FakeRemote()
        ..downloadResult = Success(Uint8List.fromList([1, 2, 3]));
      Uint8List? saved;
      final repository = AttachmentsRepositoryImpl(
        remoteDataSource: remote,
        apiBaseUri: Uri.parse('http://localhost:8080/api/v1'),
        saveDownload: (attachment, bytes) async {
          saved = bytes;
          return '/support/${attachment.originalName}';
        },
      );

      final result = await repository.download(
        _model().toEntity(Uri.parse('http://localhost:8080/api/v1')),
      );

      expect(saved, [1, 2, 3]);
      result.when(
        success: (path) => expect(path, '/support/receipt.pdf'),
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test('preserves remote failures without rewriting them', () async {
    const failure = AuthorizationFailure(message: 'forbidden');
    final remote = _FakeRemote()..listResult = const FailureResult(failure);
    final repository = AttachmentsRepositoryImpl(
      remoteDataSource: remote,
      apiBaseUri: Uri.parse('http://localhost:8080/api/v1'),
      saveDownload: (_, bytes) async => '',
    );

    final result = await repository.list(
      binding: AttachmentBinding.document(42),
    );

    result.when(
      success: (_) => fail('expected failure'),
      failure: (actual) => expect(identical(actual, failure), isTrue),
    );
  });
}

AttachmentModel _model() => AttachmentModel.fromJson(const {
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
});

PageData<AttachmentModel> _modelPage() =>
    PageData(items: [_model()], total: 1, page: 1, pageSize: 20);

final class _FakeRemote implements AttachmentsRemoteDataSource {
  Result<PageData<AttachmentModel>> listResult = Success(_modelPage());
  Result<Uint8List> downloadResult = Success(Uint8List(0));

  @override
  Future<Result<PageData<AttachmentModel>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async => listResult;

  @override
  Future<Result<AttachmentModel>> upload(
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async => Success(_model());

  @override
  Future<Result<AttachmentModel>> replace(
    int id,
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async => Success(_model());

  @override
  Future<Result<void>> reorder(
    AttachmentBinding binding,
    List<int> fileIds,
  ) async => const Success(null);

  @override
  Future<Result<Uint8List>> download(int id) async => downloadResult;

  @override
  Future<Result<void>> delete(int id) async => const Success(null);
}
