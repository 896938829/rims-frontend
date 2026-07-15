import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../repositories/auth_repository.dart';

enum SessionRefreshOrigin { request, queuedWrite, syncCenter }

typedef SessionFailClosedCallback = Future<void> Function(String accountId);
typedef SessionAuthenticationBlocker = void Function(String accountId);

abstract interface class SessionFailureRecovery {
  Future<Failure?> retainPendingRevocation(String accountId);

  Future<Failure?> completeOwnershipCleanup({
    required String accountId,
    required bool credentialQuarantined,
  });
}

final class SessionRefreshCoordinator {
  SessionRefreshCoordinator({
    required this.credentialStorage,
    required this.tokenStorage,
    required this.pendingRevocationStorage,
    required this.repository,
    this.blockAuthentication,
    this.failureRecovery,
    this.onFailClosed,
  });

  final DeviceCredentialStorage credentialStorage;
  final TokenStorage tokenStorage;
  final PendingRevocationStorage pendingRevocationStorage;
  final SessionCredentialRepository repository;
  final SessionAuthenticationBlocker? blockAuthentication;
  final SessionFailureRecovery? failureRecovery;
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
    if (current.generation < failedCredential.generation) {
      final cleanupFailure = await _failClosed(current);
      return FailureResult(
        cleanupFailure == null
            ? const StateFailure(message: 'The credential generation is stale.')
            : RevocationCleanupFailure(
                message: 'Unable to quarantine an invalid credential state.',
                cause: cleanupFailure,
              ),
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
    final Result<DeviceCredential> refreshed;
    try {
      refreshed = await repository.refreshCredential(current);
    } on Object catch (error) {
      final cleanupFailure = await _failClosed(current);
      return FailureResult(
        cleanupFailure ??
            UnknownFailure(
              message: 'Unable to refresh the device credential.',
              cause: error,
            ),
      );
    }
    if (refreshed case FailureResult<DeviceCredential>(
      failure: final failure,
    )) {
      final cleanupFailure = await _failClosed(current);
      return FailureResult(
        cleanupFailure == null
            ? failure
            : RevocationCleanupFailure(
                message: cleanupFailure.message,
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
        cleanupFailure ??
            LocalStorageFailure(
              message: 'Unable to commit rotated credentials.',
              cause: error,
            ),
      );
    }
  }

  Future<Failure?> _failClosed(DeviceCredential expected) async {
    final errors = <Object>[];
    final recovery = failureRecovery;
    var shouldBlockAuthentication = true;
    try {
      blockAuthentication?.call(expected.accountId);
    } on Object catch (error) {
      errors.add(error);
    }

    if (recovery != null) {
      try {
        final failure = await recovery.retainPendingRevocation(
          expected.accountId,
        );
        if (failure != null) errors.add(failure);
      } on Object catch (error) {
        errors.add(error);
      }
    } else {
      try {
        await pendingRevocationStorage.savePendingRevocationAccountId(
          expected.accountId,
        );
      } on Object catch (error) {
        errors.add(error);
      }
    }

    var credentialQuarantined = false;
    try {
      credentialQuarantined = await credentialStorage
          .clearDeviceCredentialIfMatches(
            accountId: expected.accountId,
            sessionId: expected.sessionId,
            generation: expected.generation,
          );
      if (!credentialQuarantined) {
        final active = await credentialStorage.readDeviceCredential();
        final sameIdentity = active != null && _sameIdentity(active, expected);
        shouldBlockAuthentication = active == null || sameIdentity;
        credentialQuarantined = !sameIdentity;
        if (!credentialQuarantined) {
          credentialQuarantined = await credentialStorage
              .clearDeviceCredentialIfMatches(
                accountId: active.accountId,
                sessionId: active.sessionId,
                generation: active.generation,
              );
        }
      }
    } on Object catch (error) {
      errors.add(error);
      try {
        await tokenStorage.clearAccessToken();
        credentialQuarantined = true;
      } on Object catch (fallbackError) {
        errors.add(fallbackError);
      }
    }

    if (recovery != null) {
      try {
        final failure = await recovery.completeOwnershipCleanup(
          accountId: expected.accountId,
          credentialQuarantined: credentialQuarantined,
        );
        if (failure != null) errors.add(failure);
      } on Object catch (error) {
        errors.add(error);
      }
    } else if (credentialQuarantined && shouldBlockAuthentication) {
      try {
        await onFailClosed?.call(expected.accountId);
      } on Object catch (error) {
        errors.add(error);
      }
    }

    return errors.isEmpty
        ? null
        : RevocationCleanupFailure(
            message: 'Unable to complete refresh credential cleanup.',
            cause: List.unmodifiable(errors),
          );
  }

  bool _sameIdentity(DeviceCredential left, DeviceCredential right) =>
      left.accountId == right.accountId && left.sessionId == right.sessionId;

  String _flightKey(DeviceCredential credential) =>
      '${credential.accountId}\u0000${credential.sessionId}\u0000'
      '${credential.generation}';
}
