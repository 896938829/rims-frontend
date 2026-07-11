import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/network/api_page_parser.dart';
import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/inventory_models.dart';

const int _inventoryListPageSize = 20;

abstract interface class InventoryRemoteDataSource {
  Future<Result<PageData<InventoryItemModel>>> listInventory({
    String keyword = '',
    int page = 1,
  });

  Future<Result<PageData<InventoryItemModel>>> listInventoryAlerts({
    int page = 1,
  });

  Future<Result<InventoryItemModel>> findProductByBarcode(String barcode);

  Future<Result<InventoryItemModel>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  });

  Future<Result<PageData<NonStandardInventoryItemModel>>>
  listNonStandardInventory({int page = 1});
}

final class ApiInventoryRemoteDataSource implements InventoryRemoteDataSource {
  const ApiInventoryRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<PageData<InventoryItemModel>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    final trimmedKeyword = keyword.trim();
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventory,
      queryParameters: {
        if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
        'page': page,
        'pageSize': _inventoryListPageSize,
      },
    );

    return _mapEnvelope(result, _parseInventoryItems);
  }

  @override
  Future<Result<PageData<InventoryItemModel>>> listInventoryAlerts({
    int page = 1,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventoryAlerts,
      queryParameters: {'page': page, 'pageSize': _inventoryListPageSize},
    );

    return _mapEnvelope(result, _parseInventoryItems);
  }

  @override
  Future<Result<InventoryItemModel>> findProductByBarcode(
    String barcode,
  ) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.productByBarcode(barcode.trim()),
    );

    return _mapEnvelope(result, _parseProductItem);
  }

  @override
  Future<Result<InventoryItemModel>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    final data = <String, int>{};
    if (alertThreshold != null) {
      data['alertThreshold'] = alertThreshold;
    }
    if (status != null) {
      data['status'] = status;
    }

    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.inventoryItem(inventoryId),
      data: data,
    );

    return _mapEnvelope(result, _parseInventoryItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItemModel>>>
  listNonStandardInventory({int page = 1}) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.nonStandardInventory,
      queryParameters: {'page': page, 'pageSize': _inventoryListPageSize},
    );

    return _mapEnvelope(result, _parseNonStandardInventoryItems);
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
            InventoryFailure(
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

  InventoryItemModel _parseProductItem(Object? data) {
    return InventoryItemModel.fromProductJson(_requiredMap(data, 'product'));
  }

  InventoryItemModel _parseInventoryItem(Object? data) {
    return InventoryItemModel.fromJson(_requiredMap(data, 'inventory'));
  }

  PageData<InventoryItemModel> _parseInventoryItems(Object? data) {
    return parseApiPage<InventoryItemModel>(
      _requiredPageData(data),
      InventoryItemModel.fromJson,
    );
  }

  PageData<NonStandardInventoryItemModel> _parseNonStandardInventoryItems(
    Object? data,
  ) {
    return parseApiPage<NonStandardInventoryItemModel>(
      _requiredPageData(data),
      NonStandardInventoryItemModel.fromJson,
    );
  }

  Map<String, Object?> _requiredPageData(Object? data) {
    if (data is Map<String, Object?>) {
      return data;
    }
    throw const FormatException('Paged API data.list must be a JSON list.');
  }

  Map<dynamic, dynamic> _requiredMap(Object? data, String name) {
    if (data is Map) {
      return data;
    }

    throw FormatException('Invalid $name response');
  }
}
