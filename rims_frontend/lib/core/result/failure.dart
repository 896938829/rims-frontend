sealed class Failure {
  const Failure({
    required this.message,
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other.runtimeType == runtimeType &&
            other is Failure &&
            other.message == message &&
            other.statusCode == statusCode;
  }

  @override
  int get hashCode => Object.hash(runtimeType, message, statusCode);

  @override
  String toString() {
    return '$runtimeType(message: $message, statusCode: $statusCode)';
  }
}

final class NetworkFailure extends Failure {
  const NetworkFailure({
    super.message = 'Network unavailable',
    super.statusCode,
    super.cause,
  });
}

final class AuthenticationFailure extends Failure {
  const AuthenticationFailure({
    super.message = 'Authentication required',
    super.statusCode,
    super.cause,
  });
}

final class AuthorizationFailure extends Failure {
  const AuthorizationFailure({
    super.message = 'Permission denied',
    super.statusCode,
    super.cause,
  });
}

final class ValidationFailure extends Failure {
  const ValidationFailure({
    super.message = 'Invalid request',
    super.statusCode,
    super.cause,
  });
}

final class NotFoundFailure extends Failure {
  const NotFoundFailure({
    super.message = 'Resource not found',
    super.statusCode,
    super.cause,
  });
}

final class ServerFailure extends Failure {
  const ServerFailure({
    super.message = 'Server error',
    super.statusCode,
    super.cause,
  });
}

final class UnknownFailure extends Failure {
  const UnknownFailure({
    super.message = 'Unexpected error',
    super.statusCode,
    super.cause,
  });
}
