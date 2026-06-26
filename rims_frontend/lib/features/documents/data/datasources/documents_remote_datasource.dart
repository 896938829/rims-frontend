import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/document_data.dart';
import '../models/document_models.dart';

abstract interface class DocumentsRemoteDataSource {
  Future<Result<List<DocumentRecordModel>>> listRecentDocuments();

  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  );
}

final class ApiDocumentsRemoteDataSource implements DocumentsRemoteDataSource {
  const ApiDocumentsRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<List<DocumentRecordModel>>> listRecentDocuments() async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.documents,
      queryParameters: const {'page': 1, 'size': 10},
    );

    return _mapEnvelope(result, _parseDocuments);
  }

  @override
  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.documents,
      data: {
        'typeCode': request.typeCode,
        'typeLabel': request.typeLabel,
        'productName': request.productName,
        'quantity': request.quantity,
      },
    );

    return _mapEnvelope(result, (data) {
      final json = data is Map ? data : const {};
      return DocumentRecordModel.fromJson(json);
    });
  }

  Result<T> _mapEnvelope<T>(
    Result<Response<dynamic>> responseResult,
    T Function(Object? data) convert,
  ) {
    return responseResult.when(
      success: (response) {
        final responseData = response.data;
        if (responseData is! Map<dynamic, dynamic>) {
          return FailureResult<T>(
            UnknownFailure(
              message: 'Invalid API response',
              statusCode: response.statusCode,
            ),
          );
        }

        final envelope = ApiEnvelope.fromJson(responseData);
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

        return Success<T>(convert(envelope.data));
      },
      failure: FailureResult<T>.new,
    );
  }

  List<DocumentRecordModel> _parseDocuments(Object? data) {
    final rawList = switch (data) {
      {'list': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      {'rows': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => const <dynamic>[],
    };

    return rawList
        .whereType<Map>()
        .map((json) => DocumentRecordModel.fromJson(json))
        .toList(growable: false);
  }
}
