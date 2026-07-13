import '../result/failure.dart';

final class ApiBusinessFailureMapper {
  const ApiBusinessFailureMapper();

  Failure map({
    required int businessCode,
    required String message,
    int? statusCode,
    String? traceId,
    Object? cause,
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
}
