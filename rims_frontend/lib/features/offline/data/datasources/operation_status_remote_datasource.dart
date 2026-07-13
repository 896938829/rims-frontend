import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/services/idempotency_key_validator.dart';

enum OperationState { processing, completed }

final class OperationStatus {
  const OperationStatus({
    required this.state,
    required this.statusCode,
    required this.expiresAt,
  });

  final OperationState state;
  final int statusCode;
  final DateTime expiresAt;

  factory OperationStatus.fromJson(Map<dynamic, dynamic> json) {
    const expectedKeys = {'state', 'status_code', 'expires_at'};
    if (json.length != expectedKeys.length ||
        !expectedKeys.every(json.containsKey)) {
      throw const FormatException(
        'Invalid idempotency operation status response',
      );
    }

    final state = switch (json['state']) {
      'processing' => OperationState.processing,
      'completed' => OperationState.completed,
      _ => throw const FormatException(
        'Invalid idempotency operation status response',
      ),
    };
    final statusCode = json['status_code'];
    if (statusCode is! int ||
        (state == OperationState.processing && statusCode != 0) ||
        (state == OperationState.completed &&
            (statusCode < 200 || statusCode >= 300))) {
      throw const FormatException(
        'Invalid idempotency operation status response',
      );
    }

    final rawExpiresAt = json['expires_at'];
    final expiresAt = rawExpiresAt is String
        ? DateTime.tryParse(rawExpiresAt)
        : null;
    if (expiresAt == null ||
        !rawExpiresAt.contains('T') ||
        !(rawExpiresAt.endsWith('Z') ||
            RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(rawExpiresAt))) {
      throw const FormatException(
        'Invalid idempotency operation status response',
      );
    }

    return OperationStatus(
      state: state,
      statusCode: statusCode,
      expiresAt: expiresAt.toUtc(),
    );
  }
}

abstract interface class OperationStatusRemoteDataSource {
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  });
}

final class ApiOperationStatusRemoteDataSource
    implements OperationStatusRemoteDataSource {
  const ApiOperationStatusRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async {
    if (!IdempotencyKeyValidator.isValid(key)) {
      return const FailureResult<OperationStatus>(
        ValidationFailure(message: 'Invalid idempotency key'),
      );
    }
    final response = await _apiClient.get<dynamic>(
      ApiEndpoints.idempotencyOperation(key),
      queryParameters: {'scope': scope},
    );
    return _mapResponse(response);
  }

  Result<OperationStatus> _mapResponse(Result<Response<dynamic>> result) {
    return result.when(
      success: (response) {
        final responseData = response.data;
        if (responseData is! Map<dynamic, dynamic>) {
          return _invalidResponse(response.statusCode);
        }

        final envelope = ApiEnvelope.fromJson(responseData);
        if (!envelope.isSuccess) {
          return FailureResult<OperationStatus>(
            UnknownFailure(
              message: envelope.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
            ),
          );
        }

        try {
          final data = envelope.data;
          if (data is! Map<dynamic, dynamic>) {
            throw const FormatException(
              'Invalid idempotency operation status response',
            );
          }
          return Success<OperationStatus>(OperationStatus.fromJson(data));
        } on FormatException catch (error) {
          return FailureResult<OperationStatus>(
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
      failure: FailureResult<OperationStatus>.new,
    );
  }

  FailureResult<OperationStatus> _invalidResponse(int? statusCode) {
    return FailureResult<OperationStatus>(
      UnknownFailure(
        message: 'Invalid idempotency operation status response',
        statusCode: statusCode,
      ),
    );
  }
}
