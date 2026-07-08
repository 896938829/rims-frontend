import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/inventory_models.dart';

const int _inventoryListPageSize = 20;

abstract interface class InventoryRemoteDataSource {
  Future<Result<List<InventoryItemModel>>> listInventory({
    String keyword = '',
    int page = 1,
  });

  Future<Result<List<InventoryItemModel>>> listInventoryAlerts({int page = 1});

  Future<Result<InventoryItemModel>> findProductByBarcode(String barcode);

  Future<Result<InventoryItemModel>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  });

  Future<Result<List<NonStandardInventoryItemModel>>> listNonStandardInventory({
    int page = 1,
  });
}

final class ApiInventoryRemoteDataSource implements InventoryRemoteDataSource {
  const ApiInventoryRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<List<InventoryItemModel>>> listInventory({
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

    return _mapEnvelope(
      result,
      (data) => _parseInventoryItems(data, 'inventory list'),
    );
  }

  @override
  Future<Result<List<InventoryItemModel>>> listInventoryAlerts({
    int page = 1,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventoryAlerts,
      queryParameters: {'page': page, 'pageSize': _inventoryListPageSize},
    );

    return _mapEnvelope(
      result,
      (data) => _parseInventoryItems(data, 'inventory alerts'),
    );
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
  Future<Result<List<NonStandardInventoryItemModel>>> listNonStandardInventory({
    int page = 1,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.nonStandardInventory,
      queryParameters: {'page': page, 'pageSize': _inventoryListPageSize},
    );

    return _mapEnvelope(
      result,
      (data) => _parseNonStandardInventoryItems(data, 'non-standard inventory'),
    );
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

  List<InventoryItemModel> _parseInventoryItems(Object? data, String name) {
    return _requiredMapItems(
      _requiredList(data, name),
      name,
    ).map((json) => InventoryItemModel.fromJson(json)).toList(growable: false);
  }

  List<NonStandardInventoryItemModel> _parseNonStandardInventoryItems(
    Object? data,
    String name,
  ) {
    return _requiredMapItems(_requiredList(data, name), name)
        .map((json) => NonStandardInventoryItemModel.fromJson(json))
        .toList(growable: false);
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

  Map<dynamic, dynamic> _requiredMap(Object? data, String name) {
    if (data is Map) {
      return data;
    }

    throw FormatException('Invalid $name response');
  }
}
