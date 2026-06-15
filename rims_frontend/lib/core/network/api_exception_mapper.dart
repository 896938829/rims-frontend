import 'package:dio/dio.dart';

import '../result/failure.dart';

final class ApiExceptionMapper {
  const ApiExceptionMapper();

  Failure map(Object error) {
    if (error is! DioException) {
      return UnknownFailure(cause: error);
    }

    final statusCode = error.response?.statusCode;
    final message = _messageFrom(error);

    if (_isNetworkError(error)) {
      return NetworkFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      );
    }

    return switch (statusCode) {
      401 => AuthenticationFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      ),
      403 => AuthorizationFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      ),
      404 => NotFoundFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      ),
      422 => ValidationFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      ),
      int code when code >= 500 && code < 600 => ServerFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
      ),
      _ => UnknownFailure(
        message: message,
        statusCode: statusCode,
        cause: error,
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
