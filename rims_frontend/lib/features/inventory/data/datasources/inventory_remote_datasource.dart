import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/inventory_models.dart';

abstract interface class InventoryRemoteDataSource {
  Future<Result<List<InventoryItemModel>>> listInventory({
    String keyword = '',
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
      },
    );

    return _mapEnvelope(result, _parseInventoryItems);
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

        return Success<T>(convert(envelope.data));
      },
      failure: FailureResult<T>.new,
    );
  }

  List<InventoryItemModel> _parseInventoryItems(Object? data) {
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
        .map((json) => InventoryItemModel.fromJson(json))
        .toList(growable: false);
  }
}
