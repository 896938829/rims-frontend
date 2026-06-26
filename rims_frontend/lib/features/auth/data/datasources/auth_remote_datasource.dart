import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/auth_models.dart';

abstract interface class AuthRemoteDataSource {
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  });

  Future<Result<List<WarehouseModel>>> loadWarehouses();
}

final class ApiAuthRemoteDataSource implements AuthRemoteDataSource {
  const ApiAuthRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

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
      (data) => LoginResponseModel.fromJson(
        data as Map<dynamic, dynamic>? ?? const {},
      ),
    );
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses() async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.currentUserWarehouses,
    );

    return _mapEnvelope(result, _parseWarehouses);
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

  List<WarehouseModel> _parseWarehouses(Object? data) {
    final rawList = switch (data) {
      {'list': final List<dynamic> list} => list,
      {'warehouses': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => const <dynamic>[],
    };

    return rawList
        .whereType<Map<dynamic, dynamic>>()
        .map(WarehouseModel.fromJson)
        .toList(growable: false);
  }
}
