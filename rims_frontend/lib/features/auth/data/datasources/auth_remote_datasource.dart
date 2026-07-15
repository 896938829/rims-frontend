import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/auth_request_policy.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/network/sanitized_transport_cause.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/auth_models.dart';

abstract interface class AuthRemoteDataSource {
  Future<Result<AppUserModel>> loadCurrentUser();

  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  });

  Future<Result<List<WarehouseModel>>> loadWarehouses({String? accessToken});

  Future<Result<WarehouseModel?>> switchCurrentWarehouse(int warehouseId);
}

abstract interface class RotatingAuthRemoteDataSource {
  Future<Result<LoginResponseModel>> refresh({required String refreshToken});

  Future<Result<void>> logout({required String accessToken});
}

abstract interface class DeviceSessionsRemoteDataSource {
  Future<Result<List<DeviceSessionModel>>> listDeviceSessions();

  Future<Result<void>> revokeDeviceSession(String sessionId);

  Future<Result<int>> revokeOtherDeviceSessions();

  Future<Result<int>> revokeAllDeviceSessions();
}

final class ApiAuthRemoteDataSource
    implements
        AuthRemoteDataSource,
        RotatingAuthRemoteDataSource,
        DeviceSessionsRemoteDataSource {
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
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.refresh,
      data: {'refreshToken': refreshToken},
      options: Options(
        headers: {'Authorization': null},
        extra: {AuthRequestPolicy.skipRefresh: true},
      ),
    );
    return _mapEnvelope(
      result,
      (data) => LoginResponseModel.fromJson(_requiredMap(data, 'refresh')),
    );
  }

  @override
  Future<Result<void>> logout({required String accessToken}) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.logout,
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        extra: {AuthRequestPolicy.skipRefresh: true},
      ),
    );
    return _mapNoContent(result);
  }

  @override
  Future<Result<List<DeviceSessionModel>>> listDeviceSessions() async {
    final result = await _apiClient.get<dynamic>(ApiEndpoints.authSessions);
    return _mapEnvelope(result, _parseDeviceSessions);
  }

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) async {
    final result = await _apiClient.delete<dynamic>(
      ApiEndpoints.authSession(sessionId),
    );
    return _mapNoContent(result);
  }

  @override
  Future<Result<int>> revokeOtherDeviceSessions() async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.revokeOtherAuthSessions,
    );
    return _mapEnvelope(result, _parseRevokedCount);
  }

  @override
  Future<Result<int>> revokeAllDeviceSessions() async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.revokeAllAuthSessions,
    );
    return _mapEnvelope(result, _parseRevokedCount);
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.currentUserWarehouses,
      options: accessToken == null
          ? null
          : Options(headers: {'Authorization': 'Bearer $accessToken'}),
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
              cause: sanitizeTransportCause(error),
            ),
          );
        }
      },
      failure: FailureResult<T>.new,
    );
  }

  Result<void> _mapNoContent(Result<Response<dynamic>> responseResult) {
    return responseResult.when(
      success: (_) => const Success<void>(null),
      failure: FailureResult<void>.new,
    );
  }

  List<DeviceSessionModel> _parseDeviceSessions(Object? data) {
    if (data is! List) {
      throw const FormatException('Invalid device sessions response');
    }
    return data
        .map((item) {
          if (item is Map) {
            return DeviceSessionModel.fromJson(
              Map<dynamic, dynamic>.from(item),
            );
          }
          throw const FormatException('Invalid device sessions response');
        })
        .toList(growable: false);
  }

  int _parseRevokedCount(Object? data) {
    final payload = _requiredMap(data, 'session revocation');
    final revoked = payload['revoked'];
    if (revoked is int && revoked >= 0) return revoked;
    throw const FormatException('Invalid session revocation response');
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
