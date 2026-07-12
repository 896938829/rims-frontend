import 'dart:typed_data';

import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/repositories/attachments_repository.dart';
import '../datasources/attachments_remote_datasource.dart';
import '../models/attachment_models.dart';

typedef SaveAttachmentDownload =
    Future<String> Function(Attachment attachment, Uint8List bytes);

final class AttachmentsRepositoryImpl implements AttachmentsRepository {
  const AttachmentsRepositoryImpl({
    required this.remoteDataSource,
    required this.apiBaseUri,
    required this.saveDownload,
  });

  final AttachmentsRemoteDataSource remoteDataSource;
  final Uri apiBaseUri;
  final SaveAttachmentDownload saveDownload;

  @override
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async {
    final result = await remoteDataSource.list(binding: binding, page: page);
    return _mapPage(result);
  }

  @override
  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async {
    final result = await remoteDataSource.upload(
      pending,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    return _mapItem(result);
  }

  @override
  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async {
    final result = await remoteDataSource.replace(
      existing.id,
      pending,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    return _mapItem(result);
  }

  @override
  Future<Result<void>> reorder(AttachmentBinding binding, List<int> fileIds) =>
      remoteDataSource.reorder(binding, fileIds);

  @override
  Future<Result<String>> download(Attachment attachment) async {
    final result = await remoteDataSource.download(attachment.id);
    return result.when(
      success: (bytes) async {
        try {
          return Success(await saveDownload(attachment, bytes));
        } catch (error) {
          return FailureResult(
            LocalStorageFailure(
              message: 'Unable to save downloaded attachment.',
              cause: error,
            ),
          );
        }
      },
      failure: (failure) async => FailureResult(failure),
    );
  }

  @override
  Future<Result<void>> delete(int id) => remoteDataSource.delete(id);

  Result<PageData<Attachment>> _mapPage(
    Result<PageData<AttachmentModel>> result,
  ) {
    return result.when(
      success: (page) {
        try {
          return Success(page.map((model) => model.toEntity(apiBaseUri)));
        } on FormatException catch (error) {
          return FailureResult(
            UnknownFailure(message: error.message, cause: error),
          );
        }
      },
      failure: FailureResult<PageData<Attachment>>.new,
    );
  }

  Result<Attachment> _mapItem(Result<AttachmentModel> result) {
    return result.when(
      success: (model) {
        try {
          return Success(model.toEntity(apiBaseUri));
        } on FormatException catch (error) {
          return FailureResult(
            UnknownFailure(message: error.message, cause: error),
          );
        }
      },
      failure: FailureResult<Attachment>.new,
    );
  }
}
