import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../repositories/auth_repository.dart';

enum SessionRefreshOrigin { request, queuedWrite, syncCenter }

typedef SessionFailClosedCallback = Future<void> Function(String accountId);

final class SessionRefreshCoordinator {
  SessionRefreshCoordinator({
    required this.credentialStorage,
    required this.tokenStorage,
    required this.pendingRevocationStorage,
    required this.repository,
    this.onFailClosed,
  });

  final DeviceCredentialStorage credentialStorage;
  final TokenStorage tokenStorage;
  final PendingRevocationStorage pendingRevocationStorage;
  final SessionCredentialRepository repository;
  final SessionFailClosedCallback? onFailClosed;

  final Map<String, Future<Result<DeviceCredential>>> _inFlight = {};

  Future<DeviceCredential?> readCurrentCredential() =>
      credentialStorage.readDeviceCredential();

  Future<Result<DeviceCredential>> refreshAfterUnauthorized({
    required DeviceCredential failedCredential,
    required SessionRefreshOrigin origin,
  }) async {
    if (origin == SessionRefreshOrigin.queuedWrite) {
      return const FailureResult(
        AuthenticationFailure(
          message: 'Queued writes require an explicit Sync Center command.',
        ),
      );
    }
    final current = await credentialStorage.readDeviceCredential();
    if (current == null || !_sameIdentity(current, failedCredential)) {
      return const FailureResult(
        AuthenticationFailure(message: 'The device session is unavailable.'),
      );
    }
    if (current.generation > failedCredential.generation) {
      return Success(current);
    }
    if (current.generation != failedCredential.generation) {
      return const FailureResult(
        StateFailure(message: 'The credential generation is stale.'),
      );
    }

    final key = _flightKey(current);
    final active = _inFlight[key];
    if (active != null) return active;
    final operation = _refresh(current);
    _inFlight[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[key], operation)) _inFlight.remove(key);
    }
  }

  Future<void> invalidateCurrent({
    required DeviceCredential expected,
    required bool retainPendingRevocation,
  }) async {
    if (retainPendingRevocation) {
      await pendingRevocationStorage.savePendingRevocationAccountId(
        expected.accountId,
      );
    }
    final cleared = await credentialStorage.clearDeviceCredentialIfMatches(
      accountId: expected.accountId,
      sessionId: expected.sessionId,
      generation: expected.generation,
    );
    if (cleared) return;
    final current = await credentialStorage.readDeviceCredential();
    if (current != null && _sameIdentity(current, expected)) {
      await credentialStorage.clearDeviceCredentialIfMatches(
        accountId: current.accountId,
        sessionId: current.sessionId,
        generation: current.generation,
      );
    }
  }

  Future<Result<DeviceCredential>> _refresh(DeviceCredential current) async {
    final refreshed = await repository.refreshCredential(current);
    if (refreshed case FailureResult<DeviceCredential>(
      failure: final failure,
    )) {
      final cleanupFailure = await _failClosed(current);
      return FailureResult(
        cleanupFailure == null
            ? failure
            : LocalStorageFailure(
                message: failure.message,
                cause: [failure, cleanupFailure],
              ),
      );
    }
    final next = (refreshed as Success<DeviceCredential>).data;
    if (!_sameIdentity(current, next) ||
        next.generation != current.generation + 1) {
      await _failClosed(current);
      return const FailureResult(
        AuthenticationFailure(message: 'Invalid rotated credential identity.'),
      );
    }
    try {
      final committed = await credentialStorage.rotateDeviceCredential(
        credential: next,
        expectedAccountId: current.accountId,
        expectedSessionId: current.sessionId,
        expectedGeneration: current.generation,
      );
      if (committed) return Success(next);
      final latest = await credentialStorage.readDeviceCredential();
      if (latest != null &&
          _sameIdentity(latest, current) &&
          latest.generation > current.generation) {
        return Success(latest);
      }
      await _failClosed(current);
      if (latest == null) {
        return const FailureResult(
          AuthenticationFailure(message: 'The device session was invalidated.'),
        );
      }
      return const FailureResult(
        StateFailure(message: 'Credential rotation was superseded.'),
      );
    } on Object catch (error) {
      final cleanupFailure = await _failClosed(current);
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to commit rotated credentials.',
          cause: [error, cleanupFailure],
        ),
      );
    }
  }

  Future<Object?> _failClosed(DeviceCredential expected) async {
    Object? firstError;
    try {
      await pendingRevocationStorage.savePendingRevocationAccountId(
        expected.accountId,
      );
    } on Object catch (error) {
      firstError = error;
    }
    var invalidatedCurrent = false;
    try {
      invalidatedCurrent = await credentialStorage
          .clearDeviceCredentialIfMatches(
            accountId: expected.accountId,
            sessionId: expected.sessionId,
            generation: expected.generation,
          );
    } on Object catch (error) {
      firstError ??= error;
      try {
        await tokenStorage.clearAccessToken();
        invalidatedCurrent = true;
      } on Object {
        // The conditional-clear error remains the primary cleanup failure.
      }
    }
    if (invalidatedCurrent) {
      try {
        await onFailClosed?.call(expected.accountId);
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    return firstError;
  }

  bool _sameIdentity(DeviceCredential left, DeviceCredential right) =>
      left.accountId == right.accountId && left.sessionId == right.sessionId;

  String _flightKey(DeviceCredential credential) =>
      '${credential.accountId}\u0000${credential.sessionId}\u0000'
      '${credential.generation}';
}
