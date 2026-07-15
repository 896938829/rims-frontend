import 'dart:async';

import '../../../../core/network/sanitized_transport_cause.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../../../core/storage/pending_revocation_journal.dart';
import 'package:uuid/uuid.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/auth_session.dart';
import '../../../auth/domain/entities/device_session.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../auth/domain/repositories/auth_repository.dart';
import '../../../auth/domain/services/session_refresh_coordinator.dart';
import '../../../auth/domain/services/authenticated_request_lease.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../../domain/services/offline_write_barrier.dart';
import 'cache_fallback.dart';
import '../services/cache_policy.dart';

final class CachedAuthRepository
    implements
        AuthRepository,
        AuthSessionRestoreMetadata,
        AuthCredentialInvalidator,
        OwnerBoundCredentialQuarantine,
        TransactionalAuthRepository,
        SessionFailureRecovery {
  CachedAuthRepository({
    required this.delegate,
    required this.store,
    required this.tokenStorage,
    required this.accountStorage,
    required this.revocationStorage,
    required this.onSessionRevoked,
    this.onSessionExpired,
    this.ownershipCoordinator,
    this.authEpochReader,
    this.revocationJournal,
    this.authTransactionOwnerFactory = _newAuthTransactionOwnerId,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  static const String _namespace = 'auth.session';
  static const String _entityKey = 'projection';
  static const String _projectionIdField = '_local_projection_id';
  static const String _projectionAttemptVersionField =
      '_local_transaction_attempt_version';
  static const String _authEpochField = '_local_auth_epoch';

  final AuthRepository delegate;
  final OfflineStore store;
  final TokenStorage tokenStorage;
  final AuthenticatedAccountStorage accountStorage;
  final PendingRevocationStorage revocationStorage;
  final OfflineOwnershipCoordinator? ownershipCoordinator;
  final int Function()? authEpochReader;
  final PendingRevocationJournal? revocationJournal;
  final String Function() authTransactionOwnerFactory;
  final FutureOr<void> Function() onSessionRevoked;
  final FutureOr<void> Function()? onSessionExpired;
  final DateTime Function() now;
  final Set<String> _volatilePendingRevocationAccountIds = {};
  final Set<SessionRevocationLease> _volatilePendingRevocationLeases = {};
  bool _revocationInvalidated = false;

  @override
  AuthSessionSource? lastRestoreSource;

  @override
  DateTime? lastRestoreFetchedAt;

  @override
  DateTime? lastRestoreExpiresAt;

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    try {
      return await _restoreSession();
    } on Object catch (error) {
      final failure =
          _revocationInvalidated ||
              _volatilePendingRevocationAccountIds.isNotEmpty ||
              _volatilePendingRevocationLeases.isNotEmpty
          ? RevocationCleanupFailure(
              message: 'Revoked credential cleanup could not be completed.',
              cause: sanitizeTransportCause(error),
            )
          : LocalStorageFailure(
              message: 'Unable to restore the local authentication session.',
              cause: sanitizeTransportCause(error),
            );
      return FailureResult(failure);
    }
  }

  Future<Result<AuthSession?>> _restoreSession() async {
    final operationEpoch = authEpochReader?.call();
    _clearMetadata();
    final pendingFailure = await _retryPendingRevocation();
    if (pendingFailure != null) return FailureResult(pendingFailure);
    await _clearAbandonedPendingToken();
    final token = (await tokenStorage.readAccessToken())?.trim();
    final accountId = await accountStorage.readAuthenticatedAccountId();
    if (token == null || token.isEmpty) {
      return delegate.restoreSession();
    }

    final result = await delegate.restoreSession();
    return switch (result) {
      Success<AuthSession?>(:final data) => _handleNetworkRestore(
        data,
        previousAccountId: accountId,
        operationEpoch: operationEpoch,
      ),
      FailureResult<AuthSession?>(failure: final failure) =>
        _handleRestoreFailure(failure, token: token, accountId: accountId),
    };
  }

  Future<Result<AuthSession?>> _handleNetworkRestore(
    AuthSession? session, {
    required String? previousAccountId,
    required int? operationEpoch,
  }) async {
    if (session == null) {
      if (previousAccountId != null) {
        final ownershipFailure = await _applyOwnership(
          OfflineOwnershipIntent.tokenExpiry(accountId: previousAccountId),
        );
        if (ownershipFailure != null) return FailureResult(ownershipFailure);
      }
      return const Success(null);
    }
    final accountId = session.user.id.toString();
    if (previousAccountId != null && previousAccountId != accountId) {
      final ownershipFailure = await _applyOwnership(
        OfflineOwnershipIntent.accountSwitch(
          previousAccountId: previousAccountId,
          currentAccountId: accountId,
        ),
      );
      if (ownershipFailure != null) return FailureResult(ownershipFailure);
    } else if (previousAccountId == accountId) {
      final ownershipFailure = await _preparePermissionRefresh(session);
      if (ownershipFailure != null) return FailureResult(ownershipFailure);
    }
    if (!_isCurrentEpoch(operationEpoch)) return _staleSessionFailure();
    final record = await _writeSession(session, expectedEpoch: operationEpoch);
    lastRestoreSource = AuthSessionSource.network;
    lastRestoreFetchedAt = record.fetchedAt;
    lastRestoreExpiresAt = record.expiresAt;
    return Success(session);
  }

  Future<Result<AuthSession?>> _handleRestoreFailure(
    Failure failure, {
    required String token,
    required String? accountId,
  }) async {
    if (failure is AuthenticationFailure) {
      await onSessionExpired?.call();
      Failure? cleanupFailure;
      if (accountId != null) {
        cleanupFailure = await _applyOwnership(
          OfflineOwnershipIntent.tokenExpiry(accountId: accountId),
        );
      }
      try {
        await _expireDelegateCredentials();
      } on Object catch (error) {
        cleanupFailure ??= LocalStorageFailure(
          message: 'Expired credential cleanup could not be completed.',
          cause: sanitizeTransportCause(error),
        );
      }
      if (cleanupFailure != null) {
        return FailureResult(
          AuthenticationFailure(
            message: failure.message,
            statusCode: failure.statusCode,
            businessCode: failure.businessCode,
            traceId: failure.traceId,
            cause: sanitizeTransportCause(cleanupFailure),
          ),
        );
      }
      return FailureResult(failure);
    }
    if (failure is AuthorizationFailure) {
      if (accountId != null) {
        final revocationFailure = await _completeRevocation(accountId);
        if (revocationFailure != null) {
          return FailureResult(revocationFailure);
        }
      }
      return FailureResult(failure);
    }
    if (!isCacheFallbackFailure(failure) || accountId == null) {
      return FailureResult(failure);
    }
    final record = await store.readCache(
      _cacheKey(accountId),
      schemaVersion: CachePolicy.references.schemaVersion,
    );
    if (record == null) {
      return FailureResult(failure);
    }
    if (!CachePolicy.references.canFallbackTo(record, now())) {
      return FailureResult(failure);
    }
    try {
      final session = _decodeSession(record.payload, token);
      if (session.user.id.toString() != accountId) {
        await _discardInvalidProjection(accountId);
        return FailureResult(failure);
      }
      lastRestoreSource = AuthSessionSource.cache;
      lastRestoreFetchedAt = record.fetchedAt;
      lastRestoreExpiresAt = record.expiresAt;
      return Success(session);
    } on Object {
      await _discardInvalidProjection(accountId);
      return FailureResult(failure);
    }
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    final prepared = await prepareLogin(username: username, password: password);
    return switch (prepared) {
      Success<AuthSessionTransaction>(data: final transaction) =>
        _commitPreparedLogin(transaction),
      FailureResult<AuthSessionTransaction>(failure: final failure) =>
        FailureResult(failure),
    };
  }

  @override
  Future<Result<AuthSessionTransaction>> prepareLogin({
    required String username,
    required String password,
  }) async {
    try {
      return await _prepareLogin(username: username, password: password);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to complete the local authentication transaction.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  Future<Result<AuthSessionTransaction>> _prepareLogin({
    required String username,
    required String password,
  }) async {
    final configuredCoordinator = ownershipCoordinator;
    final operationEpoch = authEpochReader?.call();
    final pendingFailure = await _retryPendingRevocation();
    if (pendingFailure != null) return FailureResult(pendingFailure);
    await _clearAbandonedPendingToken();
    if (configuredCoordinator != null &&
        configuredCoordinator is! OfflineReauthenticationCoordinator) {
      return const FailureResult(
        LocalStorageFailure(
          message:
              'Offline ownership coordinator does not support provisional reauthentication.',
        ),
      );
    }
    if (configuredCoordinator != null) {
      final capabilityFailure = _provisionalCapabilityFailure();
      if (capabilityFailure != null) return FailureResult(capabilityFailure);
    }
    final Result<AuthSessionTransaction> prepared;
    if (delegate case final TransactionalAuthRepository transactional) {
      prepared = await transactional.prepareLogin(
        username: username,
        password: password,
      );
    } else {
      final result = await delegate.login(
        username: username,
        password: password,
      );
      prepared = switch (result) {
        Success<AuthSession>(data: final session) => Success(
          _AlreadyCommittedAuthSessionTransaction(session),
        ),
        FailureResult<AuthSession>(failure: final failure) => FailureResult(
          failure,
        ),
      };
    }
    if (prepared case Success<AuthSessionTransaction>(data: final upstream)) {
      final provisional = switch (upstream) {
        final ProvisionalAuthSessionTransaction value => value,
        _ => null,
      };
      if (configuredCoordinator != null && provisional == null) {
        await upstream.abort();
        return const FailureResult(
          LocalStorageFailure(
            message:
                'Authentication repository returned a non-provisional login transaction.',
          ),
        );
      }
      final data = upstream.session;
      if (!_isCurrentEpoch(operationEpoch)) {
        await upstream.abort();
        return _staleSessionFailure();
      }
      final previousAccountId = await accountStorage
          .readAuthenticatedAccountId();
      final accountId = data.user.id.toString();
      if (previousAccountId != null && previousAccountId != accountId) {
        final ownershipFailure = await _applyOwnership(
          OfflineOwnershipIntent.accountSwitch(
            previousAccountId: previousAccountId,
            currentAccountId: accountId,
          ),
        );
        if (ownershipFailure != null) {
          await upstream.abort();
          return FailureResult(ownershipFailure);
        }
      }
      OfflineReauthenticationLease? reauthenticationLease;
      final coordinator = configuredCoordinator;
      if (coordinator case final OfflineReauthenticationCoordinator preparer) {
        reauthenticationLease = await preparer.prepareReauthentication(
          accountId: accountId,
        );
        if (!reauthenticationLease.report.completed) {
          _safeRollbackLease(reauthenticationLease);
          await upstream.abort();
          return FailureResult(
            _ownershipFailureFrom(reauthenticationLease.report),
          );
        }
      }
      if (!_isCurrentEpoch(operationEpoch)) {
        _safeRollbackLease(reauthenticationLease);
        await upstream.abort();
        return _staleSessionFailure();
      }
      final projectionId = authTransactionOwnerFactory();
      final projectionAttemptVersion = configuredCoordinator != null
          ? provisional?.transactionAttemptVersion
          : null;
      try {
        Future<CacheRecord> writeProjection() => _writeSession(
          data,
          expectedEpoch: operationEpoch,
          projectionId: projectionId,
          projectionAttemptVersion: projectionAttemptVersion,
        );
        if (reauthenticationLease == null) {
          await writeProjection();
        } else {
          await reauthenticationLease.runScopedWrite(writeProjection);
        }
      } on _StaleAuthOperation {
        _safeRollbackLease(reauthenticationLease);
        await upstream.abort();
        return _staleSessionFailure();
      } on Object {
        await upstream.abort();
        await _runWithLease(
          reauthenticationLease,
          () => _rollbackFailedSessionProjection(
            accountId,
            projectionId,
            projectionAttemptVersion: projectionAttemptVersion,
            propagateFailure: true,
          ),
        );
        _safeRollbackLease(reauthenticationLease);
        rethrow;
      }
      return Success(
        _CachedAuthSessionTransaction(
          session: data,
          upstream: upstream,
          rollbackProjection: () => _rollbackFailedSessionProjection(
            accountId,
            projectionId,
            projectionAttemptVersion: projectionAttemptVersion,
            propagateFailure: true,
          ),
          reauthenticationLease: reauthenticationLease,
        ),
      );
    }
    return prepared;
  }

  Future<Result<AuthSession>> _commitPreparedLogin(
    AuthSessionTransaction transaction,
  ) async {
    final committed = await transaction.commit();
    if (committed case FailureResult<void>(failure: final failure)) {
      await transaction.abort();
      return FailureResult(failure);
    }
    if (transaction case final OwnershipPreparedAuthSessionTransaction owned) {
      final Result<void> finalized;
      try {
        finalized = await owned.finalizeReauthentication();
      } on Object catch (error) {
        await transaction.abort();
        return FailureResult(
          LocalStorageFailure(
            message: 'Unable to finalize authentication ownership.',
            cause: sanitizeTransportCause(error),
          ),
        );
      }
      if (finalized case FailureResult<void>(failure: final failure)) {
        await transaction.abort();
        return FailureResult(failure);
      }
    }
    return Success(transaction.session);
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    try {
      return await _switchCurrentWarehouse(warehouse);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to update the local warehouse session.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  @override
  Future<Result<List<DeviceSession>>> listDeviceSessions() =>
      delegate.listDeviceSessions();

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) =>
      delegate.revokeDeviceSession(sessionId);

  @override
  Future<Result<int>> revokeOtherDeviceSessions() =>
      delegate.revokeOtherDeviceSessions();

  @override
  Future<Result<int>> revokeAllDeviceSessions() =>
      delegate.revokeAllDeviceSessions();

  Future<Result<Warehouse>> _switchCurrentWarehouse(Warehouse warehouse) async {
    final operationEpoch = authEpochReader?.call();
    final result = await delegate.switchCurrentWarehouse(warehouse);
    if (result case Success<Warehouse>(data: final confirmed)) {
      if (!_isCurrentEpoch(operationEpoch)) return _staleWarehouseFailure();
      final accountId = await accountStorage.readAuthenticatedAccountId();
      final token = await tokenStorage.readAccessToken();
      if (accountId != null && token != null && token.isNotEmpty) {
        final record = await store.readCache(
          _cacheKey(accountId),
          schemaVersion: CachePolicy.references.schemaVersion,
        );
        if (record != null) {
          try {
            final previous = _decodeSession(record.payload, token);
            final previousWarehouseId = previous.currentWarehouse?.id;
            if (previousWarehouseId != null &&
                previousWarehouseId != confirmed.id) {
              final ownershipFailure = await _applyOwnership(
                OfflineOwnershipIntent.warehouseSwitch(
                  accountId: accountId,
                  previousWarehouseId: previousWarehouseId,
                  currentWarehouseId: confirmed.id,
                ),
              );
              if (ownershipFailure != null) {
                return FailureResult(ownershipFailure);
              }
            }
            final updated = AuthSession(
              accessToken: token,
              user: previous.user,
              currentWarehouse: confirmed,
              warehouses: previous.warehouses
                  .map(
                    (candidate) =>
                        candidate.id == confirmed.id ? confirmed : candidate,
                  )
                  .toList(growable: false),
            );
            if (!_isCurrentEpoch(operationEpoch)) {
              return _staleWarehouseFailure();
            }
            await _writeSession(updated, expectedEpoch: operationEpoch);
          } on Object {
            await _discardInvalidProjection(accountId);
          }
        }
      }
    }
    return result;
  }

  @override
  Future<void> logout() async {
    final operationEpoch = authEpochReader?.call();
    final operationCredential = await _readCurrentCredential();
    final accountId = await accountStorage.readAuthenticatedAccountId();
    Failure? cleanupFailure;
    try {
      await delegate.logout();
    } on RevocationCleanupFailure catch (failure) {
      await onSessionExpired?.call();
      if (operationEpoch != null && operationCredential != null) {
        final cleanupLease = AuthenticatedSessionCleanupLease(
          request: AuthenticatedRequestLease(
            token: operationCredential.accessToken,
            credential: operationCredential,
            authEpoch: operationEpoch,
          ),
          cleanupEpoch: authEpochReader?.call() ?? operationEpoch,
        );
        final markerLease = SessionRevocationLease(
          accountId: operationCredential.accountId,
          sessionId: operationCredential.sessionId,
          generation: operationCredential.generation,
          authEpoch: operationEpoch,
        );
        cleanupFailure = await _retainPendingRevocationLease(
          markerLease,
          cleanupLease,
          allowCredentialMissing: true,
        );
        final active = await _readCurrentCredential();
        final ownershipFailure = await completeOwnershipCleanup(
          markerLease: markerLease,
          cleanupLease: cleanupLease,
          credentialQuarantined:
              active == null ||
              !_sameFullCredential(active, operationCredential),
        );
        cleanupFailure ??= ownershipFailure;
        if (ownershipFailure == null) {
          cleanupFailure ??= await _retainDetachedPendingRevocationLease(
            markerLease,
            cleanupLease,
          );
        }
      } else {
        cleanupFailure = accountId == null
            ? failure
            : await _retainPendingRevocationAccount(accountId);
      }
    }
    if (operationEpoch != null && !_isCurrentEpoch(operationEpoch)) return;
    if (accountId != null) {
      await _deleteSessionProjectionIfEpoch(accountId, operationEpoch ?? 0);
      if (accountStorage
          case final ConditionalAuthenticatedAccountStorage cas) {
        await cas.clearAuthenticatedAccountIfMatches(
          accountId: accountId,
          authEpoch: operationEpoch ?? 0,
        );
      } else if (operationEpoch == null || _isCurrentEpoch(operationEpoch)) {
        if (await accountStorage.readAuthenticatedAccountId() == accountId) {
          await accountStorage.clearAuthenticatedAccountId();
        }
      }
    }
    if (operationEpoch == null || _isCurrentEpoch(operationEpoch)) {
      _clearMetadata();
    }
    if (cleanupFailure != null) throw cleanupFailure;
  }

  @override
  Future<void> expireCredentials() async {
    final expected = await captureCredentialForQuarantine();
    if (expected != null) {
      if (await quarantineCredential(expected)) return;
      throw const RevocationCleanupFailure(
        message: 'Unable to quarantine the owner-bound device credential.',
      );
    }
    await _quarantineCapturedAccessToken();
    _clearMetadata();
  }

  @override
  Future<DeviceCredential?> captureCredentialForQuarantine() async {
    if (delegate case final OwnerBoundCredentialQuarantine quarantine) {
      return quarantine.captureCredentialForQuarantine();
    }
    return _readCurrentCredential();
  }

  @override
  Future<bool> quarantineCredential(DeviceCredential expected) async {
    final bool quarantined;
    if (delegate case final OwnerBoundCredentialQuarantine quarantine) {
      quarantined = await quarantine.quarantineCredential(expected);
    } else if (tokenStorage case final DeviceCredentialStorage storage) {
      final active = await storage.readDeviceCredential();
      if (!_sameFullCredential(active, expected)) return active == null;
      quarantined = tokenStorage is ConditionalTokenStorage
          ? await (tokenStorage as ConditionalTokenStorage)
                .clearAccessTokenIfMatches(expected.accessToken)
          : await storage.clearDeviceCredentialIfMatches(
              accountId: expected.accountId,
              sessionId: expected.sessionId,
              generation: expected.generation,
            );
    } else if (tokenStorage case final ConditionalTokenStorage conditional) {
      quarantined = await conditional.clearAccessTokenIfMatches(
        expected.accessToken,
      );
    } else {
      quarantined = false;
    }
    if (quarantined) _clearMetadata();
    return quarantined;
  }

  Future<CacheRecord> _writeSession(
    AuthSession session, {
    int? expectedEpoch,
    String? projectionId,
    int? projectionAttemptVersion,
  }) async {
    if (!_isCurrentEpoch(expectedEpoch)) throw const _StaleAuthOperation();
    final fetchedAt = now().toUtc();
    final accountId = session.user.id.toString();
    final payload = <String, Object?>{..._encodeSession(session)};
    if (expectedEpoch != null) payload[_authEpochField] = expectedEpoch;
    if (projectionId != null) {
      payload[_projectionIdField] = projectionId;
      if (projectionAttemptVersion != null) {
        payload[_projectionAttemptVersionField] = projectionAttemptVersion;
      }
    }
    final record = CacheRecord(
      key: _cacheKey(accountId),
      payload: payload,
      schemaVersion: CachePolicy.references.schemaVersion,
      fetchedAt: fetchedAt,
      expiresAt: CachePolicy.references.expiresAt(fetchedAt),
    );
    if (projectionId != null && projectionAttemptVersion != null) {
      final projectionStorage =
          store as AuthSessionProjectionTransactionStorage;
      final saved = await projectionStorage.saveAuthSessionProjectionIfCurrent(
        record,
        ownerId: projectionId,
        attemptVersion: projectionAttemptVersion,
      );
      if (!saved) throw const _StaleAuthOperation();
    } else {
      await store.writeCache(record);
    }
    await store.enforceCacheLimit(
      accountId: accountId,
      warehouseId: null,
      namespace: _namespace,
      maxRecords: 1,
    );
    if (!_isCurrentEpoch(expectedEpoch)) {
      await _rollbackFailedSessionProjection(
        accountId,
        projectionId,
        projectionAttemptVersion: projectionAttemptVersion,
        propagateFailure: projectionId != null,
      );
      throw const _StaleAuthOperation();
    }
    final transactional =
        accountStorage is AuthenticatedAccountTransactionStorage
        ? accountStorage as AuthenticatedAccountTransactionStorage
        : null;
    if (projectionId != null &&
        projectionAttemptVersion != null &&
        transactional != null) {
      final saved = await transactional.saveAuthenticatedAccountProjection(
        accountId: accountId,
        ownerId: projectionId,
        attemptVersion: projectionAttemptVersion,
        authEpoch: expectedEpoch,
      );
      if (!saved) throw const _StaleAuthOperation();
    } else {
      await accountStorage.saveAuthenticatedAccountId(accountId);
    }
    if (!_isCurrentEpoch(expectedEpoch)) {
      await _rollbackFailedSessionProjection(
        accountId,
        projectionId,
        projectionAttemptVersion: projectionAttemptVersion,
        propagateFailure: projectionId != null,
      );
      throw const _StaleAuthOperation();
    }
    return record;
  }

  Future<void> _rollbackFailedSessionProjection(
    String accountId,
    String? projectionId, {
    int? projectionAttemptVersion,
    bool propagateFailure = false,
  }) async {
    Object? firstError;
    try {
      if (projectionId == null) {
        await _deleteSessionProjection(accountId);
      } else {
        final projectionStorage =
            store is AuthSessionProjectionTransactionStorage
            ? store as AuthSessionProjectionTransactionStorage
            : null;
        if (projectionAttemptVersion != null && projectionStorage != null) {
          await projectionStorage.deleteAuthSessionProjectionIfOwned(
            key: _cacheKey(accountId),
            schemaVersion: CachePolicy.references.schemaVersion,
            ownerId: projectionId,
            attemptVersion: projectionAttemptVersion,
          );
        } else if (store case final ConditionalCacheRecordStorage conditional) {
          await conditional.deleteCacheRecordIfPayloadMatches(
            key: _cacheKey(accountId),
            schemaVersion: CachePolicy.references.schemaVersion,
            payloadField: _projectionIdField,
            expectedValue: projectionId,
          );
        }
      }
    } on Object catch (error) {
      firstError = error;
    }
    try {
      final transactional =
          accountStorage is AuthenticatedAccountTransactionStorage
          ? accountStorage as AuthenticatedAccountTransactionStorage
          : null;
      if (projectionId != null &&
          projectionAttemptVersion != null &&
          transactional != null) {
        await transactional.clearAuthenticatedAccountProjection(
          ownerId: projectionId,
          attemptVersion: projectionAttemptVersion,
        );
      } else if (await accountStorage.readAuthenticatedAccountId() ==
          accountId) {
        await accountStorage.clearAuthenticatedAccountId();
      }
    } on Object catch (error) {
      firstError ??= error;
    }
    if (propagateFailure && firstError != null) throw firstError;
  }

  Future<void> _discardInvalidProjection(String accountId) async {
    await _applyOwnership(
      OfflineOwnershipIntent.invalidSessionProjection(accountId: accountId),
    );
    await accountStorage.clearAuthenticatedAccountId();
  }

  Future<void> _expireDelegateCredentials() async {
    Object? firstError;
    try {
      await _quarantineCapturedAccessToken();
    } on Object catch (error) {
      firstError = error;
    }
    try {
      if (delegate case final AuthCredentialInvalidator invalidator) {
        await invalidator.expireCredentials();
      }
    } on Object catch (error) {
      firstError ??= error;
    }
    if (firstError != null) throw firstError;
  }

  Future<void> _quarantineCapturedAccessToken() async {
    final accessToken = await tokenStorage.readAccessToken();
    if (accessToken == null || accessToken.isEmpty) return;
    if (tokenStorage case final ConditionalTokenStorage conditional) {
      if (await conditional.clearAccessTokenIfMatches(accessToken)) return;
    }
    throw const RevocationCleanupFailure(
      message: 'Unable to quarantine the captured access token.',
    );
  }

  @override
  Future<Failure?> retainPendingRevocation({
    required SessionRevocationLease markerLease,
    required AuthenticatedSessionCleanupLease cleanupLease,
  }) async {
    if (!await _isCleanupCurrent(cleanupLease)) return null;
    return _retainPendingRevocationLease(markerLease, cleanupLease);
  }

  Future<Failure?> _retainPendingRevocationLease(
    SessionRevocationLease marker,
    AuthenticatedSessionCleanupLease expected, {
    bool allowCredentialMissing = false,
  }) async {
    _volatilePendingRevocationLeases.add(marker);
    _revocationInvalidated = true;
    final errors = <Object>[];
    var journalRetained = false;
    var primaryRetained = false;
    final journal = revocationJournal;
    if (journal case final SessionPendingRevocationJournal sessionJournal) {
      try {
        if (!await _isCleanupCurrent(
          expected,
          allowCredentialMissing: allowCredentialMissing,
        )) {
          _volatilePendingRevocationLeases.remove(marker);
          return null;
        }
        await sessionJournal.addLease(marker);
        journalRetained = true;
        if (!await _isCleanupCurrent(
          expected,
          allowCredentialMissing: allowCredentialMissing,
        )) {
          await sessionJournal.removeLease(marker);
          _volatilePendingRevocationLeases.remove(marker);
          return null;
        }
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (revocationStorage
        case final SessionPendingRevocationStorage sessionStorage) {
      try {
        if (!await _isCleanupCurrent(
          expected,
          allowCredentialMissing: allowCredentialMissing,
        )) {
          if (journalRetained) {
            if (journal
                case final SessionPendingRevocationJournal sessionJournal) {
              await sessionJournal.removeLease(marker);
            }
          }
          _volatilePendingRevocationLeases.remove(marker);
          return null;
        }
        await sessionStorage.savePendingRevocationLease(marker);
        primaryRetained = true;
        if (!await _isCleanupCurrent(
          expected,
          allowCredentialMissing: allowCredentialMissing,
        )) {
          await sessionStorage.clearPendingRevocationLeaseIfMatches(marker);
          if (journalRetained) {
            if (journal
                case final SessionPendingRevocationJournal sessionJournal) {
              await sessionJournal.removeLease(marker);
            }
          }
          _volatilePendingRevocationLeases.remove(marker);
          return null;
        }
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (journalRetained || primaryRetained) return null;
    _volatilePendingRevocationLeases.remove(marker);
    return RevocationCleanupFailure(
      message: 'Unable to retain pending credential revocation.',
      cause: sanitizeTransportCause(errors),
    );
  }

  Future<Failure?> _retainDetachedPendingRevocationLease(
    SessionRevocationLease marker,
    AuthenticatedSessionCleanupLease expected,
  ) async {
    if (!_isCleanupEpochCurrent(expected)) return null;
    final active = await _readCurrentCredential();
    if (active != null) return null;
    final errors = <Object>[];
    var retained = false;
    if (revocationJournal
        case final SessionPendingRevocationJournal sessionJournal) {
      try {
        await sessionJournal.addLease(marker);
        retained = true;
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (revocationStorage
        case final SessionPendingRevocationStorage sessionStorage) {
      try {
        await sessionStorage.savePendingRevocationLease(marker);
        retained = true;
      } on Object catch (error) {
        errors.add(error);
      }
    }
    if (!_isCleanupEpochCurrent(expected) ||
        await _readCurrentCredential() != null) {
      await _releasePendingRevocationLease(marker);
      return null;
    }
    if (retained) {
      _volatilePendingRevocationLeases.add(marker);
      _revocationInvalidated = true;
      return null;
    }
    return RevocationCleanupFailure(
      message: 'Unable to retain pending credential revocation.',
      cause: sanitizeTransportCause(errors),
    );
  }

  Future<Failure?> _retainPendingRevocationAccount(String accountId) async {
    _volatilePendingRevocationAccountIds.add(accountId);
    _revocationInvalidated = true;
    final errors = <Object>[];
    var journalRetained = false;
    var primaryRetained = false;
    final journal = revocationJournal;
    if (journal != null) {
      try {
        await journal.addAccountId(accountId);
        journalRetained = true;
      } on Object catch (error) {
        errors.add(error);
      }
    }
    try {
      final primary = await revocationStorage.readPendingRevocationAccountId();
      if (primary == null || primary == accountId) {
        await revocationStorage.savePendingRevocationAccountId(accountId);
        primaryRetained = true;
      }
    } on Object catch (error) {
      errors.add(error);
    }
    if (journalRetained || primaryRetained) return null;
    return RevocationCleanupFailure(
      message: 'Unable to retain pending credential revocation.',
      cause: sanitizeTransportCause(errors),
    );
  }

  @override
  Future<Failure?> completeOwnershipCleanup({
    required SessionRevocationLease markerLease,
    required AuthenticatedSessionCleanupLease cleanupLease,
    required bool credentialQuarantined,
    bool ownershipCompleted = false,
  }) async {
    final expected = cleanupLease;
    if (!await _isCleanupCurrent(
      expected,
      allowCredentialMissing: true,
      requireAccount: false,
    )) {
      return _handleSupersededCleanup(markerLease, expected);
    }
    final accountId = expected.request.credential.accountId;
    Object? firstError;
    if (!credentialQuarantined) {
      firstError = const RevocationCleanupFailure(
        message: 'The failed credential could not be quarantined.',
      );
    }
    try {
      if (await _isCleanupCurrent(
        expected,
        allowCredentialMissing: true,
        requireAccount: false,
      )) {
        await _deleteSessionProjectionIfEpoch(accountId, markerLease.authEpoch);
      }
    } on OfflineWriteBlockedException {
      // The active fail-closed transition already blocks offline writes.
    } on Object catch (error) {
      firstError ??= error;
    }
    if (!await _isCleanupCurrent(
      expected,
      allowCredentialMissing: true,
      requireAccount: false,
    )) {
      return _handleSupersededCleanup(markerLease, expected);
    }
    try {
      if (accountStorage
          case final ConditionalAuthenticatedAccountStorage cas) {
        await cas.clearAuthenticatedAccountIfMatches(
          accountId: accountId,
          authEpoch: markerLease.authEpoch,
        );
      } else if (await _isCleanupCurrent(
        expected,
        allowCredentialMissing: true,
        requireAccount: false,
      )) {
        await accountStorage.clearAuthenticatedAccountId();
      }
    } on Object catch (error) {
      firstError ??= error;
    }
    if (!await _isCleanupCurrent(
      expected,
      allowCredentialMissing: true,
      requireAccount: false,
    )) {
      return _handleSupersededCleanup(markerLease, expected);
    }
    final ownershipFailure = ownershipCompleted
        ? null
        : await _applyOwnership(
            OfflineOwnershipIntent.tokenExpiry(accountId: accountId),
          );
    if (!await _isCleanupCurrent(
      expected,
      allowCredentialMissing: true,
      requireAccount: false,
    )) {
      return _handleSupersededCleanup(markerLease, expected);
    }
    firstError ??= ownershipFailure;
    if (firstError == null) {
      try {
        await _releasePendingRevocationLease(markerLease);
      } on Object catch (error) {
        firstError = error;
      }
    }
    if (firstError != null) {
      return RevocationCleanupFailure(
        message: firstError is Failure
            ? firstError.message
            : 'Refresh credential cleanup could not be completed.',
        cause: sanitizeTransportCause(firstError),
      );
    }
    _volatilePendingRevocationAccountIds.remove(accountId);
    _volatilePendingRevocationLeases.remove(markerLease);
    _updateRevocationInvalidated();
    return null;
  }

  Future<RevocationCleanupFailure?> _completeRevocation(
    String accountId, {
    bool notifyRevocation = true,
  }) async {
    if (notifyRevocation) await onSessionRevoked();
    Object? firstError = await _retainPendingRevocationAccount(accountId);
    // Quarantine every independently recoverable projection before cleanup.
    try {
      await _expireDelegateCredentials();
    } on Object catch (error) {
      firstError ??= error;
    }
    try {
      await accountStorage.clearAuthenticatedAccountId();
    } on Object catch (error) {
      firstError ??= error;
    }
    try {
      await _deleteSessionProjection(accountId);
    } on OfflineWriteBlockedException {
      // A same-process revocation retry can inherit the fail-closed barrier
      // established only after this projection was already quarantined.
    } on Object catch (error) {
      firstError ??= error;
    }
    final ownershipFailure = await _applyOwnership(
      OfflineOwnershipIntent.revocation(accountId: accountId),
    );
    if (ownershipFailure != null) {
      firstError ??= ownershipFailure;
    }
    if (firstError == null) {
      try {
        await _releasePendingRevocation(accountId);
      } on Object catch (error) {
        firstError = error;
      }
    }
    if (firstError != null) {
      return RevocationCleanupFailure(
        message: firstError is Failure
            ? firstError.message
            : 'Revoked credential cleanup could not be completed.',
        cause: sanitizeTransportCause(firstError),
      );
    }
    _volatilePendingRevocationAccountIds.remove(accountId);
    _revocationInvalidated = _volatilePendingRevocationAccountIds.isNotEmpty;
    return null;
  }

  Future<RevocationCleanupFailure?> _retryPendingRevocation() async {
    String? durablePendingRevocation;
    SessionRevocationLease? durablePendingLease;
    Set<String> journalPending = const {};
    Set<SessionRevocationLease> journalPendingLeases = const {};
    Object? primaryReadError;
    try {
      durablePendingRevocation = await revocationStorage
          .readPendingRevocationAccountId();
      if (revocationStorage
          case final SessionPendingRevocationStorage sessionStorage) {
        durablePendingLease = await sessionStorage.readPendingRevocationLease();
        if (durablePendingLease != null) durablePendingRevocation = null;
      }
    } on Object catch (error) {
      primaryReadError = error;
    }
    try {
      journalPending = await revocationJournal?.readAccountIds() ?? const {};
      if (revocationJournal
          case final SessionPendingRevocationJournal sessionJournal) {
        journalPendingLeases = await sessionJournal.readLeases();
      }
    } on Object catch (error) {
      return RevocationCleanupFailure(
        message: 'Pending credential revocation could not be verified.',
        cause: sanitizeTransportCause(error),
      );
    }
    if (primaryReadError != null &&
        journalPending.isEmpty &&
        journalPendingLeases.isEmpty &&
        _volatilePendingRevocationAccountIds.isEmpty) {
      return RevocationCleanupFailure(
        message: 'Pending credential revocation could not be verified.',
        cause: sanitizeTransportCause(primaryReadError),
      );
    }
    final pendingLeases = <SessionRevocationLease>{
      ..._volatilePendingRevocationLeases,
      ...journalPendingLeases,
      ?durablePendingLease,
    };
    for (final marker in pendingLeases) {
      final credential = await _readCurrentCredential();
      if (credential == null) {
        final accountId = await accountStorage.readAuthenticatedAccountId();
        if (accountId != null && accountId != marker.accountId) {
          await _releasePendingRevocationLease(marker);
          continue;
        }
        await onSessionRevoked();
        final failure = await _completeDetachedMarkerCleanup(
          marker,
          cleanupEpoch: authEpochReader?.call() ?? marker.authEpoch,
        );
        if (failure != null) return failure;
        continue;
      }
      if (credential.accountId != marker.accountId ||
          credential.sessionId != marker.sessionId ||
          credential.generation != marker.generation) {
        await _releasePendingRevocationLease(marker);
        continue;
      }
      final requestLease = AuthenticatedRequestLease(
        token: credential.accessToken,
        credential: credential,
        authEpoch: marker.authEpoch,
      );
      await onSessionRevoked();
      final expected = AuthenticatedSessionCleanupLease(
        request: requestLease,
        cleanupEpoch: authEpochReader?.call() ?? marker.authEpoch,
      );
      var quarantined = false;
      if (tokenStorage case final DeviceCredentialStorage credentialStorage) {
        quarantined = await credentialStorage.clearDeviceCredentialIfMatches(
          accountId: marker.accountId,
          sessionId: marker.sessionId,
          generation: marker.generation,
        );
      }
      final failure = await completeOwnershipCleanup(
        markerLease: marker,
        cleanupLease: expected,
        credentialQuarantined: quarantined,
      );
      if (failure != null) {
        return RevocationCleanupFailure(
          message: failure.message,
          cause: sanitizeTransportCause(failure),
        );
      }
    }
    final pendingRevocations = <String>{
      ..._volatilePendingRevocationAccountIds,
      ...journalPending,
      ?durablePendingRevocation,
    };
    if (pendingRevocations.isEmpty) return null;
    if (await _readCurrentCredential() != null) {
      for (final accountId in pendingRevocations) {
        await _releasePendingRevocation(accountId);
        _volatilePendingRevocationAccountIds.remove(accountId);
      }
      _updateRevocationInvalidated();
      return null;
    }
    _volatilePendingRevocationAccountIds.addAll(pendingRevocations);
    _revocationInvalidated = true;
    final ordered = pendingRevocations.toList()..sort();
    if (durablePendingRevocation != null) {
      ordered
        ..remove(durablePendingRevocation)
        ..insert(0, durablePendingRevocation);
    }
    for (final accountId in ordered) {
      final failure = await _completeRevocation(
        accountId,
        notifyRevocation: true,
      );
      if (failure != null) return failure;
    }
    return null;
  }

  Future<void> _clearAbandonedPendingToken() async {
    if (tokenStorage case final AuthTokenTransactionStorage transaction) {
      await transaction.clearPendingAccessToken();
    }
  }

  Future<void> _clearPendingRevocationIfMatches(String accountId) async {
    if (revocationStorage
        case final ConditionalPendingRevocationStorage conditional) {
      await conditional.clearPendingRevocationAccountIdIfMatches(accountId);
      return;
    }
    if (await revocationStorage.readPendingRevocationAccountId() == accountId) {
      await revocationStorage.clearPendingRevocationAccountId();
    }
  }

  Future<void> _releasePendingRevocation(String accountId) async {
    await revocationJournal?.removeAccountId(accountId);
    await _clearPendingRevocationIfMatches(accountId);
  }

  Future<void> _releasePendingRevocationLease(
    SessionRevocationLease marker,
  ) async {
    if (revocationJournal
        case final SessionPendingRevocationJournal sessionJournal) {
      await sessionJournal.removeLease(marker);
    }
    if (revocationStorage
        case final SessionPendingRevocationStorage sessionStorage) {
      await sessionStorage.clearPendingRevocationLeaseIfMatches(marker);
    }
    _volatilePendingRevocationLeases.remove(marker);
    _updateRevocationInvalidated();
  }

  Future<bool> _isCleanupCurrent(
    AuthenticatedSessionCleanupLease expected, {
    bool allowCredentialMissing = false,
    bool requireAccount = true,
  }) async {
    if (!_isCleanupEpochCurrent(expected)) return false;
    final before = await _readCurrentCredential();
    if (!_isCleanupEpochCurrent(expected) ||
        !_credentialMatchesCleanup(
          before,
          expected.request.credential,
          allowMissing: allowCredentialMissing,
        )) {
      return false;
    }
    final accountId = await accountStorage.readAuthenticatedAccountId();
    if (!_isCleanupEpochCurrent(expected) ||
        (requireAccount &&
            accountId != expected.request.credential.accountId) ||
        (!requireAccount &&
            accountId != null &&
            accountId != expected.request.credential.accountId)) {
      return false;
    }
    final after = await _readCurrentCredential();
    return _isCleanupEpochCurrent(expected) &&
        _credentialMatchesCleanup(
          after,
          expected.request.credential,
          allowMissing: allowCredentialMissing,
        );
  }

  bool _credentialMatchesCleanup(
    DeviceCredential? active,
    DeviceCredential expected, {
    required bool allowMissing,
  }) =>
      (allowMissing && active == null) || _sameFullCredential(active, expected);

  Future<DeviceCredential?> _readCurrentCredential() async {
    if (tokenStorage case final DeviceCredentialStorage credentialStorage) {
      return credentialStorage.readDeviceCredential();
    }
    return null;
  }

  Future<Failure?> _handleSupersededCleanup(
    SessionRevocationLease marker,
    AuthenticatedSessionCleanupLease cleanup,
  ) async {
    final active = await _readCurrentCredential();
    if (active != null &&
        !_sameFullCredential(active, cleanup.request.credential)) {
      await _releasePendingRevocationLease(marker);
      return null;
    }
    return const RevocationCleanupFailure(
      message: 'The session cleanup lease was superseded before completion.',
    );
  }

  Future<RevocationCleanupFailure?> _completeDetachedMarkerCleanup(
    SessionRevocationLease marker, {
    required int cleanupEpoch,
  }) async {
    bool isCurrent() =>
        authEpochReader == null || authEpochReader?.call() == cleanupEpoch;
    if (!isCurrent()) {
      return const RevocationCleanupFailure(
        message: 'The detached session cleanup lease is stale.',
      );
    }
    Object? firstError;
    try {
      await _deleteSessionProjectionIfEpoch(marker.accountId, marker.authEpoch);
    } on OfflineWriteBlockedException {
      // The active recovery transition already blocks offline writes.
    } on Object catch (error) {
      firstError = error;
    }
    if (!isCurrent()) {
      return const RevocationCleanupFailure(
        message: 'The detached session cleanup lease is stale.',
      );
    }
    try {
      if (accountStorage
          case final ConditionalAuthenticatedAccountStorage cas) {
        await cas.clearAuthenticatedAccountIfMatches(
          accountId: marker.accountId,
          authEpoch: marker.authEpoch,
        );
      } else if (await accountStorage.readAuthenticatedAccountId() ==
          marker.accountId) {
        await accountStorage.clearAuthenticatedAccountId();
      }
    } on Object catch (error) {
      firstError ??= error;
    }
    if (!isCurrent()) {
      return const RevocationCleanupFailure(
        message: 'The detached session cleanup lease is stale.',
      );
    }
    firstError ??= await _applyOwnership(
      OfflineOwnershipIntent.tokenExpiry(accountId: marker.accountId),
    );
    if (!isCurrent()) {
      return const RevocationCleanupFailure(
        message: 'The detached session cleanup lease is stale.',
      );
    }
    if (firstError != null) {
      return RevocationCleanupFailure(
        message: firstError is Failure
            ? firstError.message
            : 'Detached session cleanup could not be completed.',
        cause: sanitizeTransportCause(firstError),
      );
    }
    await _releasePendingRevocationLease(marker);
    return null;
  }

  bool _sameFullCredential(
    DeviceCredential? active,
    DeviceCredential expected,
  ) =>
      active?.accountId == expected.accountId &&
      active?.sessionId == expected.sessionId &&
      active?.generation == expected.generation &&
      active?.accessToken == expected.accessToken &&
      active?.refreshToken == expected.refreshToken &&
      active?.tokenVersion == expected.tokenVersion;

  void _updateRevocationInvalidated() {
    _revocationInvalidated =
        _volatilePendingRevocationAccountIds.isNotEmpty ||
        _volatilePendingRevocationLeases.isNotEmpty;
  }

  bool _isCleanupEpochCurrent(AuthenticatedSessionCleanupLease expected) =>
      authEpochReader == null ||
      authEpochReader?.call() == expected.cleanupEpoch;

  Future<void> _deleteSessionProjectionIfEpoch(
    String accountId,
    int authEpoch,
  ) async {
    if (store case final ConditionalCacheRecordStorage conditional) {
      await conditional.deleteCacheRecordIfPayloadMatches(
        key: _cacheKey(accountId),
        schemaVersion: CachePolicy.references.schemaVersion,
        payloadField: _authEpochField,
        expectedValue: authEpoch,
      );
    }
  }

  Future<Failure?> _applyOwnership(OfflineOwnershipIntent intent) async {
    final coordinator = ownershipCoordinator;
    if (coordinator == null) return null;
    final report = await coordinator.apply(intent);
    if (report.completed) return null;
    return LocalStorageFailure(
      message: report.failures.map((failure) => failure.message).join(' '),
      cause: sanitizeTransportCause(report),
    );
  }

  LocalStorageFailure _ownershipFailureFrom(OfflineOwnershipReport report) {
    return LocalStorageFailure(
      message: report.failures.map((failure) => failure.message).join(' '),
      cause: sanitizeTransportCause(report),
    );
  }

  Result<void> _safeRollbackLease(OfflineReauthenticationLease? lease) {
    if (lease == null) return const Success(null);
    try {
      return lease.rollback();
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to roll back reauthentication ownership.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  Future<T> _runWithLease<T>(
    OfflineReauthenticationLease? lease,
    Future<T> Function() operation,
  ) => lease == null
      ? Future<T>.sync(operation)
      : lease.runScopedWrite(operation);

  LocalStorageFailure? _provisionalCapabilityFailure() {
    final repository = delegate is ProvisionalTransactionalAuthRepository
        ? delegate as ProvisionalTransactionalAuthRepository
        : null;
    if (repository == null) {
      return const LocalStorageFailure(
        message:
            'Authentication repository does not support provisional credential transactions.',
      );
    }
    if (tokenStorage is! AuthTokenTransactionStorage ||
        !identical(repository.tokenTransactionStorageIdentity, tokenStorage)) {
      return const LocalStorageFailure(
        message:
            'Authentication token storage does not support the required owner/version transaction.',
      );
    }
    if (accountStorage is! AuthenticatedAccountTransactionStorage) {
      return const LocalStorageFailure(
        message:
            'Authenticated account storage does not support owner/version rollback.',
      );
    }
    final projectionStorage = store is AuthSessionProjectionTransactionStorage
        ? store as AuthSessionProjectionTransactionStorage
        : null;
    if (projectionStorage == null ||
        !projectionStorage.supportsAuthSessionProjectionTransactions) {
      return const LocalStorageFailure(
        message:
            'Session projection storage does not support scoped transaction rollback.',
      );
    }
    return null;
  }

  Future<Failure?> _preparePermissionRefresh(AuthSession session) async {
    final accountId = session.user.id.toString();
    final record = await store.readCache(
      _cacheKey(accountId),
      schemaVersion: CachePolicy.references.schemaVersion,
    );
    if (record == null) return null;
    late final AuthSession previous;
    try {
      previous = _decodeSession(record.payload, session.accessToken);
    } on Object {
      await _discardInvalidProjection(accountId);
      return null;
    }
    if (_authorizationFingerprint(previous) ==
        _authorizationFingerprint(session)) {
      return null;
    }
    return _applyOwnership(
      OfflineOwnershipIntent.permissionRefresh(accountId: accountId),
    );
  }

  String _authorizationFingerprint(AuthSession session) {
    final permissions = session.user.permissionCodes.toList()..sort();
    return '${session.user.roleCode}:${permissions.join(',')}';
  }

  void _clearMetadata() {
    lastRestoreSource = null;
    lastRestoreFetchedAt = null;
    lastRestoreExpiresAt = null;
  }

  bool _isCurrentEpoch(int? expected) =>
      expected == null || authEpochReader?.call() == expected;

  Future<void> _deleteSessionProjection(String accountId) {
    return store.deleteCacheNamespace(
      accountId: accountId,
      namespace: _namespace,
    );
  }

  FailureResult<T> _staleSessionFailure<T>() => FailureResult<T>(
    const StateFailure(message: 'Authentication operation was superseded.'),
  );

  FailureResult<Warehouse> _staleWarehouseFailure() =>
      const FailureResult<Warehouse>(
        StateFailure(message: 'Warehouse switch was superseded.'),
      );
}

String _newAuthTransactionOwnerId() => const Uuid().v4();

final class _CachedAuthSessionTransaction
    implements AuthSessionTransaction, OwnershipPreparedAuthSessionTransaction {
  const _CachedAuthSessionTransaction({
    required this.session,
    required this.upstream,
    required this.rollbackProjection,
    required this.reauthenticationLease,
  });

  @override
  final AuthSession session;
  final AuthSessionTransaction upstream;
  final Future<void> Function() rollbackProjection;
  final OfflineReauthenticationLease? reauthenticationLease;

  @override
  bool get hasPreparedReauthentication => reauthenticationLease != null;

  @override
  Future<Result<void>> finalizeReauthentication() async {
    final lease = reauthenticationLease;
    if (lease == null) return const Success(null);
    try {
      final finalized = await lease.finalize();
      return switch (finalized) {
        Success<OfflineOwnershipReport>() => const Success(null),
        FailureResult<OfflineOwnershipReport>(failure: final failure) =>
          FailureResult(failure),
      };
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to finalize reauthentication ownership.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  @override
  Future<Result<void>> commit() async {
    Result<void> result;
    try {
      result = await upstream.commit();
    } on Object catch (error) {
      result = FailureResult(
        LocalStorageFailure(
          message: 'Unable to commit the local authentication session.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
    if (result is Success<void>) return result;
    Failure? projectionFailure;
    try {
      await _runProjectionRollback();
    } on Object catch (error) {
      projectionFailure = LocalStorageFailure(
        message: 'Unable to roll back the failed authentication session.',
        cause: sanitizeTransportCause(error),
      );
    }
    final leaseFailure = _rollbackLease();
    if (projectionFailure == null && leaseFailure == null) return result;
    final originalFailure = switch (result) {
      FailureResult<void>(failure: final failure) => failure,
      _ => null,
    };
    return FailureResult(
      LocalStorageFailure(
        message: [
          if (originalFailure != null) originalFailure.message,
          if (projectionFailure != null) projectionFailure.message,
          if (leaseFailure != null) leaseFailure.message,
        ].join(' '),
        cause: sanitizeTransportCause([
          originalFailure,
          projectionFailure,
          leaseFailure,
        ]),
      ),
    );
  }

  @override
  Future<Result<void>> abort() async {
    final failures = <Failure>[];
    Result<void> upstreamResult;
    try {
      upstreamResult = await upstream.abort();
    } on Object catch (error) {
      upstreamResult = FailureResult(
        LocalStorageFailure(
          message: 'Unable to abort the local credential transaction.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
    if (upstreamResult case FailureResult<void>(failure: final failure)) {
      failures.add(failure);
    }
    try {
      await _runProjectionRollback();
    } on Object catch (error) {
      failures.add(
        LocalStorageFailure(
          message: 'Unable to roll back the local session projection.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
    final leaseFailure = _rollbackLease();
    if (leaseFailure != null) failures.add(leaseFailure);
    if (failures.isEmpty) return const Success(null);
    return FailureResult(
      LocalStorageFailure(
        message: failures.map((failure) => failure.message).join(' '),
        cause: sanitizeTransportCause(failures),
      ),
    );
  }

  Failure? _rollbackLease() {
    final lease = reauthenticationLease;
    if (lease == null) return null;
    try {
      return switch (lease.rollback()) {
        Success<void>() => null,
        FailureResult<void>(failure: final failure) => failure,
      };
    } on Object catch (error) {
      return LocalStorageFailure(
        message: 'Unable to roll back reauthentication ownership.',
        cause: sanitizeTransportCause(error),
      );
    }
  }

  Future<void> _runProjectionRollback() {
    final lease = reauthenticationLease;
    return lease == null
        ? rollbackProjection()
        : lease.runScopedWrite(rollbackProjection);
  }
}

final class _AlreadyCommittedAuthSessionTransaction
    implements AuthSessionTransaction {
  const _AlreadyCommittedAuthSessionTransaction(this.session);

  @override
  final AuthSession session;

  @override
  Future<Result<void>> abort() async => const Success(null);

  @override
  Future<Result<void>> commit() async => const Success(null);
}

final class _StaleAuthOperation implements Exception {
  const _StaleAuthOperation();
}

CacheKey _cacheKey(String accountId) => CacheKey(
  accountId: accountId,
  namespace: CachedAuthRepository._namespace,
  entityKey: CachedAuthRepository._entityKey,
);

Map<String, Object?> _encodeSession(AuthSession session) => {
  'user': {
    'id': session.user.id,
    'username': session.user.username,
    'real_name': session.user.realName,
    'role_code': session.user.roleCode,
    'role_name': session.user.roleName,
    'permission_codes': session.user.permissionCodes.toList()..sort(),
  },
  'current_warehouse_id': session.currentWarehouse?.id,
  'warehouses': session.warehouses.map(_encodeWarehouse).toList(),
};

Map<String, Object?> _encodeWarehouse(Warehouse warehouse) => {
  'id': warehouse.id,
  'code': warehouse.code,
  'name': warehouse.name,
  'is_default': warehouse.isDefault,
};

AuthSession _decodeSession(Map<String, Object?> payload, String token) {
  final userPayload = Map<String, Object?>.from(payload['user']! as Map);
  final warehouses = (payload['warehouses']! as List)
      .map((value) => _decodeWarehouse(Map<String, Object?>.from(value as Map)))
      .toList(growable: false);
  final currentWarehouseId = payload['current_warehouse_id'] as int?;
  Warehouse? currentWarehouse;
  for (final warehouse in warehouses) {
    if (warehouse.id == currentWarehouseId) currentWarehouse = warehouse;
  }
  return AuthSession(
    accessToken: token,
    user: AppUser(
      id: userPayload['id']! as int,
      username: userPayload['username']! as String,
      realName: userPayload['real_name']! as String,
      roleCode: userPayload['role_code']! as String,
      roleName: userPayload['role_name']! as String,
      permissionCodes: Set.unmodifiable(
        ((userPayload['permission_codes'] as List?) ?? const []).map(
          (value) => value.toString(),
        ),
      ),
    ),
    currentWarehouse: currentWarehouse,
    warehouses: warehouses,
  );
}

Warehouse _decodeWarehouse(Map<String, Object?> payload) => Warehouse(
  id: payload['id']! as int,
  code: payload['code']! as String,
  name: payload['name']! as String,
  isDefault: payload['is_default']! as bool,
);
