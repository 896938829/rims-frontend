import 'package:dio/dio.dart';

import '../result/failure.dart';
import 'api_envelope.dart';

final class ApiExceptionMapper {
  const ApiExceptionMapper();

  Failure map(Object error) {
    if (error is! DioException) {
      return UnknownFailure(cause: error);
    }

    final statusCode = error.response?.statusCode;
    final envelope = _envelopeFrom(error.response?.data);
    final message = envelope?.message ?? _messageFrom(error);
    final businessCode = envelope?.code;
    final traceId = envelope?.traceId;

    if (_isNetworkError(error)) {
      return NetworkFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: error,
      );
    }

    if (businessCode != null && businessCode != 0) {
      return _failureFromBusinessCode(
        businessCode,
        message: message,
        statusCode: statusCode,
        traceId: traceId,
        cause: error,
      );
    }

    return _failureFromStatusCode(
      statusCode,
      message: message,
      businessCode: businessCode == 0 ? null : businessCode,
      traceId: traceId,
      cause: error,
    );
  }

  Failure _failureFromBusinessCode(
    int businessCode, {
    required String message,
    required int? statusCode,
    required String? traceId,
    required Object cause,
  }) {
    return switch (businessCode) {
      10001 => AuthenticationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      10002 => AuthorizationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      10003 => ValidationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      10004 => NotFoundFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      10005 || 20003 => ConflictFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      20001 => InventoryFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      20002 => StateFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      50000 => ServerFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      _ => UnknownFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
    };
  }

  Failure _failureFromStatusCode(
    int? statusCode, {
    required String message,
    required int? businessCode,
    required String? traceId,
    required Object cause,
  }) {
    return switch (statusCode) {
      400 || 422 => ValidationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      401 => AuthenticationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      403 => AuthorizationFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      404 => NotFoundFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      409 => ConflictFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      int code when code >= 500 && code < 600 => ServerFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
      _ => UnknownFailure(
        message: message,
        statusCode: statusCode,
        businessCode: businessCode,
        traceId: traceId,
        cause: cause,
      ),
    };
  }

  bool _isNetworkError(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };
  }

  ApiEnvelope? _envelopeFrom(Object? data) {
    if (data is Map<dynamic, dynamic>) {
      return ApiEnvelope.fromJson(data);
    }

    return null;
  }

  String _messageFrom(DioException error) {
    final data = error.response?.data;
    final responseMessage = _messageFromData(data);

    if (responseMessage != null) {
      return responseMessage;
    }

    if (error.message case final message? when message.isNotEmpty) {
      return message;
    }

    return 'Request failed';
  }

  String? _messageFromData(Object? data) {
    if (data is String && data.isNotEmpty) {
      return data;
    }

    if (data is! Map) {
      return null;
    }

    final directMessage = _firstStringValue(data, const [
      'message',
      'error',
      'detail',
    ]);
    if (directMessage != null) {
      return directMessage;
    }

    return _validationMessage(data['errors']);
  }

  String? _firstStringValue(Map<dynamic, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  String? _validationMessage(Object? errors) {
    if (errors is! Map) {
      return null;
    }

    final parts = <String>[];

    for (final entry in errors.entries) {
      final field = entry.key.toString();
      final message = _validationValueMessage(entry.value);

      if (field.isNotEmpty && message != null) {
        parts.add('$field: $message');
      }
    }

    if (parts.isEmpty) {
      return null;
    }

    return parts.join('; ');
  }

  String? _validationValueMessage(Object? value) {
    if (value is String && value.isNotEmpty) {
      return value;
    }

    if (value is Iterable) {
      final messages = value
          .whereType<String>()
          .where((message) => message.isNotEmpty)
          .toList();

      if (messages.isNotEmpty) {
        return messages.join(', ');
      }
    }

    return null;
  }
}
