import 'dart:collection';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../repositories/auth_repository.dart';
import 'authenticated_request_lease.dart';

enum SessionRefreshOrigin { request, queuedWrite, syncCenter }

typedef SessionFailClosedCallback = Future<void> Function(String accountId);
typedef SessionAuthenticationBlocker =
    int? Function(AuthenticatedRequestLease expected);

abstract interface class SessionFailureRecovery {
  Future<Failure?> retainPendingRevocation(
    AuthenticatedSessionCleanupLease expected,
  );

  Future<Failure?> completeOwnershipCleanup({
    required AuthenticatedSessionCleanupLease expected,
    required bool credentialQuarantined,
  });
}

final class SessionRefreshCoordinator {
  static const int _maxQuarantinedLeases = 128;

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
  final LinkedHashSet<String> _quarantinedCredentials = LinkedHashSet();

  Future<DeviceCredential?> readCurrentCredential() =>
      credentialStorage.readDeviceCredential();

  void observeStableLease(AuthenticatedRequestLease lease) {
    final stableKey = _flightKey(lease.credential, lease.authEpoch);
    _quarantinedCredentials.removeWhere((key) => key != stableKey);
  }

  Future<Result<DeviceCredential>> refreshAfterUnauthorized({
    required DeviceCredential failedCredential,
    int failedAuthEpoch = 0,
    required SessionRefreshOrigin origin,
  }) async {
    if (origin == SessionRefreshOrigin.queuedWrite) {
      return const FailureResult(
        AuthenticationFailure(
          message: 'Queued writes require an explicit Sync Center command.',
        ),
      );
    }
    final DeviceCredential? current;
    try {
      current = await credentialStorage.readDeviceCredential();
    } on Object catch (error) {
      final cleanupFailure = await _failClosed(
        failedCredential,
        failedAuthEpoch,
      );
      return FailureResult(
        cleanupFailure == null
            ? LocalStorageFailure(
                message: 'Unable to read the current device credential.',
                cause: error,
              )
            : RevocationCleanupFailure(
                message: cleanupFailure.message,
                cause: [error, cleanupFailure],
              ),
      );
    }
    if (current == null || !_sameIdentity(current, failedCredential)) {
      return const FailureResult(
        AuthenticationFailure(message: 'The device session is unavailable.'),
      );
    }
    if (current.generation > failedCredential.generation) {
      return Success(current);
    }
    if (_quarantinedCredentials.contains(
      _flightKey(failedCredential, failedAuthEpoch),
    )) {
      return const FailureResult(
        AuthenticationFailure(message: 'The device session is quarantined.'),
      );
    }
    if (current.generation < failedCredential.generation) {
      final cleanupFailure = await _failClosed(current, failedAuthEpoch);
      return FailureResult(
        cleanupFailure == null
            ? const StateFailure(message: 'The credential generation is stale.')
            : RevocationCleanupFailure(
                message: 'Unable to quarantine an invalid credential state.',
                cause: cleanupFailure,
              ),
      );
    }

    final key = _flightKey(current, failedAuthEpoch);
    final active = _inFlight[key];
    if (active != null) return active;
    final operation = _refresh(current, failedAuthEpoch);
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

  Future<Result<DeviceCredential>> _refresh(
    DeviceCredential current,
    int authEpoch,
  ) async {
    final Result<DeviceCredential> refreshed;
    try {
      refreshed = await repository.refreshCredential(current);
    } on Object catch (error) {
      final cleanupFailure = await _failClosed(current, authEpoch);
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
      final cleanupFailure = await _failClosed(current, authEpoch);
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
      await _failClosed(current, authEpoch);
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
      await _failClosed(current, authEpoch);
      if (latest == null) {
        return const FailureResult(
          AuthenticationFailure(message: 'The device session was invalidated.'),
        );
      }
      return const FailureResult(
        StateFailure(message: 'Credential rotation was superseded.'),
      );
    } on Object catch (error) {
      final cleanupFailure = await _failClosed(current, authEpoch);
      return FailureResult(
        cleanupFailure ??
            LocalStorageFailure(
              message: 'Unable to commit rotated credentials.',
              cause: error,
            ),
      );
    }
  }

  Future<Failure?> _failClosed(DeviceCredential expected, int authEpoch) async {
    _quarantine(expected, authEpoch);
    final errors = <Object>[];
    final recovery = failureRecovery;
    final requestLease = AuthenticatedRequestLease(
      token: expected.accessToken,
      credential: expected,
      authEpoch: authEpoch,
    );
    try {
      final active = await credentialStorage.readDeviceCredential();
      if (active != null && !_sameCredential(active, expected)) return null;
    } on Object catch (error) {
      errors.add(error);
    }
    final int cleanupEpoch;
    if (blockAuthentication case final blocker?) {
      try {
        final blockedEpoch = blocker(requestLease);
        if (blockedEpoch == null) return null;
        cleanupEpoch = blockedEpoch;
      } on Object catch (error) {
        return RevocationCleanupFailure(
          message: 'Unable to block the failed authentication lease.',
          cause: error,
        );
      }
    } else {
      cleanupEpoch = authEpoch;
    }
    final cleanupLease = AuthenticatedSessionCleanupLease(
      request: requestLease,
      cleanupEpoch: cleanupEpoch,
    );
    var shouldBlockAuthentication = true;

    if (recovery != null) {
      try {
        final failure = await recovery.retainPendingRevocation(cleanupLease);
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
          expected: cleanupLease,
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

  bool _sameCredential(DeviceCredential left, DeviceCredential right) =>
      _sameIdentity(left, right) && left.generation == right.generation;

  String _flightKey(DeviceCredential credential, int authEpoch) =>
      '${credential.accountId}\u0000${credential.sessionId}\u0000'
      '${credential.generation}\u0000$authEpoch';

  void _quarantine(DeviceCredential credential, int authEpoch) {
    final key = _flightKey(credential, authEpoch);
    _quarantinedCredentials
      ..remove(key)
      ..add(key);
    while (_quarantinedCredentials.length > _maxQuarantinedLeases) {
      _quarantinedCredentials.remove(_quarantinedCredentials.first);
    }
  }
}
