import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/auth_models.dart';

abstract interface class AuthRemoteDataSource {
  Future<Result<AppUserModel>> loadCurrentUser();

  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  });

  Future<Result<List<WarehouseModel>>> loadWarehouses();

  Future<Result<WarehouseModel?>> switchCurrentWarehouse(int warehouseId);
}

final class ApiAuthRemoteDataSource implements AuthRemoteDataSource {
  const ApiAuthRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async {
    final result = await _apiClient.get<dynamic>(ApiEndpoints.currentUser);

    return _mapEnvelope(
      result,
      (data) => AppUserModel.fromJson(_requiredMap(data, 'current user')),
    );
  }

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.login,
      data: {'username': username, 'password': password},
    );

    return _mapEnvelope(
      result,
      (data) => LoginResponseModel.fromJson(_requiredMap(data, 'login')),
    );
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses() async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.currentUserWarehouses,
    );

    return _mapEnvelope(result, _parseWarehouses);
  }

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.currentUserCurrentWarehouse,
      data: {'warehouseId': warehouseId},
    );

    return _mapEnvelope<WarehouseModel?>(result, (data) {
      if (data == null) {
        return null;
      }

      return WarehouseModel.fromJson(_requiredMap(data, 'warehouse'));
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

  List<WarehouseModel> _parseWarehouses(Object? data) {
    final rawList = switch (data) {
      {'list': final List<dynamic> list} => list,
      {'warehouses': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      {'rows': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => throw const FormatException('Invalid warehouses response'),
    };

    return rawList
        .map((item) {
          if (item is Map) {
            return WarehouseModel.fromJson(Map<dynamic, dynamic>.from(item));
          }

          throw const FormatException('Invalid warehouses response');
        })
        .toList(growable: false);
  }

  Map<dynamic, dynamic> _requiredMap(Object? data, String name) {
    if (data is Map) {
      return Map<dynamic, dynamic>.from(data);
    }

    throw FormatException('Invalid $name response');
  }
}
