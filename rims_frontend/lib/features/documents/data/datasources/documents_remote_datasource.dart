import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/document_data.dart';
import '../models/document_models.dart';

abstract interface class DocumentsRemoteDataSource {
  Future<Result<List<DocumentRecordModel>>> listRecentDocuments({
    int? docType,
    int page = 1,
  });

  Future<Result<List<TransactionRecordModel>>> listTransactions({
    String keyword = '',
    int page = 1,
  });

  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  );

  Future<Result<void>> completeDocument(int id);

  Future<Result<void>> confirmDocument(int id);

  Future<Result<void>> settleDocument(int id);
}

final class ApiDocumentsRemoteDataSource implements DocumentsRemoteDataSource {
  const ApiDocumentsRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<List<DocumentRecordModel>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    final queryParameters = <String, Object>{'page': page, 'pageSize': 10};
    if (docType != null) {
      queryParameters['docType'] = docType;
    }

    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.documents,
      queryParameters: queryParameters,
    );

    return _mapEnvelope(result, _parseDocuments);
  }

  @override
  Future<Result<List<TransactionRecordModel>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    final trimmedKeyword = keyword.trim();
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.transactions,
      queryParameters: {
        'page': page,
        'pageSize': 10,
        if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
      },
    );

    return _mapEnvelope(result, _parseTransactions);
  }

  @override
  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.documents,
      data: {
        'docType': request.docType,
        if (request.toWarehouseId != null)
          'toWarehouseId': request.toWarehouseId,
        if (request.refDocId != null) 'refDocId': request.refDocId,
        'lines': [
          {
            if (request.nonStdInventoryId != null)
              'nonStdInvId': request.nonStdInventoryId,
            'productId': request.productId,
            if (request.retailPrice != null) 'retailPrice': request.retailPrice,
            if (request.actualQuantity == null) 'quantity': request.quantity,
            if (request.actualQuantity != null)
              'actualQty': request.actualQuantity,
          },
        ],
      },
    );

    return _mapEnvelope(
      result,
      (data) => DocumentRecordModel.fromJson(_requiredMap(data, 'document')),
    );
  }

  @override
  Future<Result<void>> completeDocument(int id) async {
    final result = await _apiClient.post<dynamic>(
      '${ApiEndpoints.documents}/$id/complete',
    );

    return _mapEmptySuccess(result);
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    final result = await _apiClient.post<dynamic>(
      '${ApiEndpoints.documents}/$id/confirm',
    );

    return _mapEmptySuccess(result);
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    final result = await _apiClient.post<dynamic>(
      '${ApiEndpoints.documents}/$id/settle',
    );

    return _mapEmptySuccess(result);
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

        try {
          return Success<T>(convert(envelope.data));
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

  Result<void> _mapEmptySuccess(Result<Response<dynamic>> responseResult) {
    return responseResult.when(
      success: (response) {
        final responseData = response.data;
        if (response.statusCode == 204 ||
            responseData == null ||
            responseData == '') {
          return const Success<void>(null);
        }

        if (responseData is Map<dynamic, dynamic>) {
          final envelope = ApiEnvelope.fromJson(responseData);
          if (envelope.isSuccess) {
            return const Success<void>(null);
          }

          return FailureResult<void>(
            UnknownFailure(
              message: envelope.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
            ),
          );
        }

        return FailureResult<void>(
          UnknownFailure(
            message: 'Invalid API response',
            statusCode: response.statusCode,
          ),
        );
      },
      failure: FailureResult<void>.new,
    );
  }

  List<DocumentRecordModel> _parseDocuments(Object? data) {
    final rawList = _requiredList(data, 'documents');

    return _requiredMapItems(
      rawList,
      'documents',
    ).map((json) => DocumentRecordModel.fromJson(json)).toList(growable: false);
  }

  List<TransactionRecordModel> _parseTransactions(Object? data) {
    final rawList = _requiredList(data, 'transactions');

    return _requiredMapItems(rawList, 'transactions')
        .map((json) => TransactionRecordModel.fromJson(json))
        .toList(growable: false);
  }

  Map<dynamic, dynamic> _requiredMap(Object? data, String name) {
    if (data is Map) {
      return data;
    }

    throw FormatException('Invalid $name response');
  }

  List<dynamic> _requiredList(Object? data, String name) {
    return switch (data) {
      {'list': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      {'rows': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => throw FormatException('Invalid $name response'),
    };
  }

  List<Map<dynamic, dynamic>> _requiredMapItems(
    List<dynamic> list,
    String name,
  ) {
    return list
        .map((item) {
          if (item is Map) {
            return Map<dynamic, dynamic>.from(item);
          }

          throw FormatException('Invalid $name response');
        })
        .toList(growable: false);
  }
}
