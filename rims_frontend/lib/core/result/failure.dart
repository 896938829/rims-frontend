sealed class Failure {
  const Failure({
    required this.message,
    this.statusCode,
    this.businessCode,
    this.traceId,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final int? businessCode;
  final String? traceId;
  final Object? cause;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other.runtimeType == runtimeType &&
            other is Failure &&
            other.message == message &&
            other.statusCode == statusCode &&
            other.businessCode == businessCode &&
            other.traceId == traceId;
  }

  @override
  int get hashCode {
    return Object.hash(runtimeType, message, statusCode, businessCode, traceId);
  }

  @override
  String toString() {
    return '$runtimeType('
        'message: $message, '
        'statusCode: $statusCode, '
        'businessCode: $businessCode, '
        'traceId: $traceId'
        ')';
  }
}

final class NetworkFailure extends Failure {
  const NetworkFailure({
    super.message = 'Network unavailable',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class TransportUnknownFailure extends Failure {
  const TransportUnknownFailure({
    super.message = 'Transport result is unknown',
    super.cause,
  });
}

final class CancellationFailure extends Failure {
  const CancellationFailure({
    super.message = 'Operation cancelled',
    super.cause,
  });
}

final class DevicePermissionFailure extends Failure {
  const DevicePermissionFailure({required super.message, super.cause});
}

final class LocalStorageFailure extends Failure {
  const LocalStorageFailure({required super.message, super.cause});
}

final class AttachmentFailure extends Failure {
  const AttachmentFailure({required super.message, super.cause});
}

final class AuthenticationFailure extends Failure {
  const AuthenticationFailure({
    super.message = 'Authentication required',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class AuthorizationFailure extends Failure {
  const AuthorizationFailure({
    super.message = 'Permission denied',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class ValidationFailure extends Failure {
  const ValidationFailure({
    super.message = 'Invalid request',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class NotFoundFailure extends Failure {
  const NotFoundFailure({
    super.message = 'Resource not found',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class ConflictFailure extends Failure {
  const ConflictFailure({
    super.message = 'Resource conflict',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class InventoryFailure extends Failure {
  const InventoryFailure({
    super.message = 'Inventory operation failed',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class StateFailure extends Failure {
  const StateFailure({
    super.message = 'State transition failed',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class UnsupportedOperationFailure extends Failure {
  const UnsupportedOperationFailure({
    super.message = 'Operation is not supported by this app',
    super.cause,
  });
}

final class ServerFailure extends Failure {
  const ServerFailure({
    super.message = 'Server error',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}

final class UnknownFailure extends Failure {
  const UnknownFailure({
    super.message = 'Unexpected error',
    super.statusCode,
    super.businessCode,
    super.traceId,
    super.cause,
  });
}
