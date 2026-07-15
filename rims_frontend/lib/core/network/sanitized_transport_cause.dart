import 'package:dio/dio.dart';

import '../result/failure.dart';

final class SanitizedTransportCause {
  const SanitizedTransportCause({
    required this.transportType,
    required this.statusCode,
  });

  final String transportType;
  final int? statusCode;

  @override
  String toString() =>
      'SanitizedTransportCause(type: $transportType, statusCode: $statusCode)';
}

final class SanitizedOpaqueCause {
  const SanitizedOpaqueCause(this.sourceType);

  final String sourceType;

  @override
  String toString() => 'SanitizedOpaqueCause(type: $sourceType)';
}

Object? sanitizeTransportCause(Object? cause) {
  if (cause == null) return null;
  if (cause is DioException) {
    return SanitizedTransportCause(
      transportType: cause.type.name,
      statusCode: cause.response?.statusCode,
    );
  }
  if (cause is Failure) return _copyFailure(cause, 'Nested failure redacted');
  if (cause is Iterable) {
    return List<Object?>.unmodifiable(cause.map(sanitizeTransportCause));
  }
  return SanitizedOpaqueCause(cause.runtimeType.toString());
}

Failure sanitizeFailureCause(Failure failure) =>
    _copyFailure(failure, failure.message);

Failure _copyFailure(Failure failure, String message) {
  final cause = sanitizeTransportCause(failure.cause);
  return switch (failure) {
    NetworkFailure() => NetworkFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    TransportUnknownFailure() => TransportUnknownFailure(
      message: message,
      cause: cause,
    ),
    CancellationFailure() => CancellationFailure(
      message: message,
      cause: cause,
    ),
    DevicePermissionFailure() => DevicePermissionFailure(
      message: message,
      cause: cause,
    ),
    LocalStorageFailure() => LocalStorageFailure(
      message: message,
      cause: cause,
    ),
    RevocationCleanupFailure() => RevocationCleanupFailure(
      message: message,
      cause: cause,
    ),
    AttachmentFailure() => AttachmentFailure(message: message, cause: cause),
    AuthenticationFailure() => AuthenticationFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    AuthorizationFailure() => AuthorizationFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    ValidationFailure() => ValidationFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    NotFoundFailure() => NotFoundFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    ConflictFailure() => ConflictFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    InventoryFailure() => InventoryFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    StateFailure() => StateFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    UnsupportedOperationFailure() => UnsupportedOperationFailure(
      message: message,
      cause: cause,
    ),
    ServerFailure() => ServerFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
    UnknownFailure() => UnknownFailure(
      message: message,
      statusCode: failure.statusCode,
      businessCode: failure.businessCode,
      traceId: failure.traceId,
      cause: cause,
    ),
  };
}
