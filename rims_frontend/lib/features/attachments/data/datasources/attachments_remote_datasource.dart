import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/network/api_page_parser.dart';
import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/attachment.dart';
import '../models/attachment_models.dart';

const int _attachmentPageSize = 20;

abstract interface class AttachmentsRemoteDataSource {
  Future<Result<PageData<AttachmentModel>>> list({
    required AttachmentBinding binding,
    int page = 1,
  });
  Future<Result<AttachmentModel>> upload(
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  });
  Future<Result<AttachmentModel>> replace(
    int id,
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  });
  Future<Result<void>> reorder(AttachmentBinding binding, List<int> fileIds);
  Future<Result<Uint8List>> download(int id);
  Future<Result<void>> delete(int id);
}

final class ApiAttachmentsRemoteDataSource
    implements AttachmentsRemoteDataSource {
  const ApiAttachmentsRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<PageData<AttachmentModel>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async {
    final response = await _apiClient.get<dynamic>(
      ApiEndpoints.files,
      queryParameters: {
        'businessType': binding.businessType,
        'businessId': binding.businessId,
        'page': page,
        'pageSize': _attachmentPageSize,
      },
    );
    return _mapEnvelope(
      response,
      (data) => parseApiPage<AttachmentModel>(
        _requiredObject(data, 'attachment page'),
        AttachmentModel.fromJson,
      ),
    );
  }

  @override
  Future<Result<AttachmentModel>> upload(
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    if (cancellation.isCancelled) {
      return const FailureResult(CancellationFailure());
    }
    final form = FormData.fromMap({
      'businessType': pending.binding.businessType,
      'businessId': pending.binding.businessId.toString(),
      'file': await MultipartFile.fromFile(
        pending.stagedPath,
        filename: pending.originalName,
      ),
    });
    return _sendMultipart(
      path: ApiEndpoints.fileUpload,
      form: form,
      requestId: pending.requestId,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  @override
  Future<Result<AttachmentModel>> replace(
    int id,
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    if (cancellation.isCancelled) {
      return const FailureResult(CancellationFailure());
    }
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        pending.stagedPath,
        filename: pending.originalName,
      ),
    });
    return _sendMultipart(
      path: ApiEndpoints.fileReplace(id),
      form: form,
      requestId: pending.requestId,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<Result<AttachmentModel>> _sendMultipart({
    required String path,
    required FormData form,
    required String requestId,
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    final cancelToken = CancelToken();
    void cancelRequest() => cancelToken.cancel('attachment transfer cancelled');
    cancellation.addListener(cancelRequest);
    try {
      final response = await _apiClient.post<dynamic>(
        path,
        data: form,
        options: Options(headers: {'Idempotency-Key': requestId}),
        cancelToken: cancelToken,
        onSendProgress: onProgress,
      );
      return _mapEnvelope(response, _parseItem);
    } finally {
      cancellation.removeListener(cancelRequest);
    }
  }

  @override
  Future<Result<void>> reorder(
    AttachmentBinding binding,
    List<int> fileIds,
  ) async {
    final response = await _apiClient.put<dynamic>(
      ApiEndpoints.fileReorder,
      data: {
        'businessType': binding.businessType,
        'businessId': binding.businessId,
        'fileIds': List<int>.unmodifiable(fileIds),
      },
    );
    return _mapEnvelope<void>(response, (data) {
      if (data is! List<Object?>) {
        throw const FormatException('Attachment reorder data must be a list.');
      }
    });
  }

  @override
  Future<Result<Uint8List>> download(int id) async {
    final response = await _apiClient.get<Uint8List>(
      ApiEndpoints.fileDownload(id),
      options: Options(responseType: ResponseType.bytes),
    );
    return response.when(
      success: (value) {
        final bytes = value.data;
        if (bytes == null) {
          return const FailureResult(
            UnknownFailure(message: 'Attachment download returned no bytes.'),
          );
        }
        return Success(bytes);
      },
      failure: FailureResult<Uint8List>.new,
    );
  }

  @override
  Future<Result<void>> delete(int id) async {
    final response = await _apiClient.delete<void>(ApiEndpoints.file(id));
    return response.when(
      success: (_) => const Success<void>(null),
      failure: FailureResult<void>.new,
    );
  }

  Result<T> _mapEnvelope<T>(
    Result<Response<dynamic>> responseResult,
    T Function(Object? data) convert,
  ) {
    return responseResult.when(
      success: (response) {
        final body = response.data;
        if (body is! Map<dynamic, dynamic>) {
          return FailureResult<T>(
            UnknownFailure(
              message: 'Invalid attachment API response.',
              statusCode: response.statusCode,
            ),
          );
        }
        final envelope = ApiEnvelope.fromJson(body);
        if (!envelope.isSuccess) {
          return FailureResult<T>(
            UnknownFailure(
              message: envelope.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
            ),
          );
        }
        try {
          return Success(convert(envelope.data));
        } on FormatException catch (error) {
          return FailureResult<T>(
            UnknownFailure(
              message: error.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
              cause: error,
            ),
          );
        }
      },
      failure: FailureResult<T>.new,
    );
  }

  AttachmentModel _parseItem(Object? data) {
    return AttachmentModel.fromJson(_requiredObject(data, 'attachment'));
  }

  Map<String, Object?> _requiredObject(Object? data, String name) {
    if (data is Map<String, Object?>) return data;
    throw FormatException('Invalid $name response.');
  }
}
