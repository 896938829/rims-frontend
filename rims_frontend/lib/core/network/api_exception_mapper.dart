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

    if (data is Map<String, dynamic>) {
      final message = data['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }

    if (error.message case final message? when message.isNotEmpty) {
      return message;
    }

    return 'Request failed';
  }
}
