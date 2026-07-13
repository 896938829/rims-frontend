import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../../../core/storage/pending_revocation_journal.dart';
import 'package:uuid/uuid.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/auth_session.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../auth/domain/repositories/auth_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../../domain/services/offline_write_barrier.dart';
import '../services/cache_policy.dart';

final class CachedAuthRepository
    implements
        AuthRepository,
        AuthSessionRestoreMetadata,
        AuthCredentialInvalidator,
        TransactionalAuthRepository {
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

  final AuthRepository delegate;
  final OfflineStore store;
  final TokenStorage tokenStorage;
  final AuthenticatedAccountStorage accountStorage;
  final PendingRevocationStorage revocationStorage;
  final OfflineOwnershipCoordinator? ownershipCoordinator;
  final int Function()? authEpochReader;
  final PendingRevocationJournal? revocationJournal;
  final String Function() authTransactionOwnerFactory;
  final void Function() onSessionRevoked;
  final void Function()? onSessionExpired;
  final DateTime Function() now;
  final Set<String> _volatilePendingRevocationAccountIds = {};
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
              _volatilePendingRevocationAccountIds.isNotEmpty
          ? RevocationCleanupFailure(
              message: 'Revoked credential cleanup could not be completed.',
              cause: error,
            )
          : LocalStorageFailure(
              message: 'Unable to restore the local authentication session.',
              cause: error,
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
      onSessionExpired?.call();
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
          cause: error,
        );
      }
      if (cleanupFailure != null) {
        return FailureResult(
          AuthenticationFailure(
            message: failure.message,
            statusCode: failure.statusCode,
            businessCode: failure.businessCode,
            traceId: failure.traceId,
            cause: cleanupFailure,
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
    if (failure is! NetworkFailure || accountId == null) {
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
          cause: error,
        ),
      );
    }
  }

  Future<Result<AuthSessionTransaction>> _prepareLogin({
    required String username,
    required String password,
  }) async {
    final operationEpoch = authEpochReader?.call();
    final pendingFailure = await _retryPendingRevocation();
    if (pendingFailure != null) return FailureResult(pendingFailure);
    await _clearAbandonedPendingToken();
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
      final reauthenticationFailure = await _applyOwnership(
        OfflineOwnershipIntent.reauthenticated(accountId: accountId),
      );
      if (reauthenticationFailure != null) {
        await upstream.abort();
        return FailureResult(reauthenticationFailure);
      }
      if (!_isCurrentEpoch(operationEpoch)) {
        await upstream.abort();
        return _staleSessionFailure();
      }
      final projectionId = authTransactionOwnerFactory();
      try {
        await _writeSession(
          data,
          expectedEpoch: operationEpoch,
          projectionId: projectionId,
        );
      } on _StaleAuthOperation {
        await upstream.abort();
        return _staleSessionFailure();
      } on Object {
        await upstream.abort();
        await _rollbackFailedSessionProjection(
          accountId,
          projectionId,
          propagateFailure: true,
        );
        rethrow;
      }
      return Success(
        _CachedAuthSessionTransaction(
          session: data,
          upstream: upstream,
          rollbackProjection: () => _rollbackFailedSessionProjection(
            accountId,
            projectionId,
            propagateFailure: true,
          ),
        ),
      );
    }
    return prepared;
  }

  Future<Result<AuthSession>> _commitPreparedLogin(
    AuthSessionTransaction transaction,
  ) async {
    final committed = await transaction.commit();
    return switch (committed) {
      Success<void>() => Success(transaction.session),
      FailureResult<void>(failure: final failure) => () async {
        await transaction.abort();
        return FailureResult<AuthSession>(failure);
      }(),
    };
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    try {
      return await _switchCurrentWarehouse(warehouse);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to update the local warehouse session.',
          cause: error,
        ),
      );
    }
  }

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
    final accountId = await accountStorage.readAuthenticatedAccountId();
    await delegate.logout();
    if (accountId != null) await accountStorage.clearAuthenticatedAccountId();
    _clearMetadata();
  }

  @override
  Future<void> expireCredentials() async {
    if (delegate case final AuthCredentialInvalidator invalidator) {
      await invalidator.expireCredentials();
    } else {
      await delegate.logout();
    }
    _clearMetadata();
  }

  Future<CacheRecord> _writeSession(
    AuthSession session, {
    int? expectedEpoch,
    String? projectionId,
  }) async {
    if (!_isCurrentEpoch(expectedEpoch)) throw const _StaleAuthOperation();
    final fetchedAt = now().toUtc();
    final accountId = session.user.id.toString();
    final record = CacheRecord(
      key: _cacheKey(accountId),
      payload: {
        ..._encodeSession(session),
        ...projectionId == null
            ? const <String, Object?>{}
            : {_projectionIdField: projectionId},
      },
      schemaVersion: CachePolicy.references.schemaVersion,
      fetchedAt: fetchedAt,
      expiresAt: CachePolicy.references.expiresAt(fetchedAt),
    );
    await store.writeCache(record);
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
        propagateFailure: projectionId != null,
      );
      throw const _StaleAuthOperation();
    }
    final transactional =
        accountStorage is AuthenticatedAccountTransactionStorage
        ? accountStorage as AuthenticatedAccountTransactionStorage
        : null;
    if (projectionId != null && transactional != null) {
      await transactional.saveAuthenticatedAccountProjection(
        accountId: accountId,
        projectionId: projectionId,
      );
    } else {
      await accountStorage.saveAuthenticatedAccountId(accountId);
    }
    if (!_isCurrentEpoch(expectedEpoch)) {
      await _rollbackFailedSessionProjection(
        accountId,
        projectionId,
        propagateFailure: projectionId != null,
      );
      throw const _StaleAuthOperation();
    }
    return record;
  }

  Future<void> _rollbackFailedSessionProjection(
    String accountId,
    String? projectionId, {
    bool propagateFailure = false,
  }) async {
    Object? firstError;
    try {
      if (projectionId == null) {
        await _deleteSessionProjection(accountId);
      } else {
        final projectionStore = store is WriteBarrierOfflineStore
            ? (store as WriteBarrierOfflineStore).delegate
            : store;
        if (projectionStore
            case final ConditionalCacheRecordStorage conditional) {
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
      if (projectionId != null && transactional != null) {
        await transactional.clearAuthenticatedAccountProjection(projectionId);
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
      await tokenStorage.clearAccessToken();
    } on Object catch (error) {
      firstError = error;
    }
    try {
      if (delegate case final AuthCredentialInvalidator invalidator) {
        await invalidator.expireCredentials();
      } else {
        await delegate.logout();
      }
    } on Object catch (error) {
      firstError ??= error;
    }
    if (firstError != null) throw firstError;
  }

  Future<RevocationCleanupFailure?> _completeRevocation(
    String accountId, {
    bool notifyRevocation = true,
  }) async {
    _volatilePendingRevocationAccountIds.add(accountId);
    _revocationInvalidated = true;
    if (notifyRevocation) onSessionRevoked();
    Object? firstError;
    try {
      await revocationJournal?.addAccountId(accountId);
    } on Object catch (error) {
      firstError = error;
    }
    try {
      final primary = await revocationStorage.readPendingRevocationAccountId();
      if (primary == null || primary == accountId) {
        await revocationStorage.savePendingRevocationAccountId(accountId);
      }
    } on Object catch (error) {
      firstError ??= error;
    }
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
        await revocationJournal?.removeAccountId(accountId);
        await _clearPendingRevocationIfMatches(accountId);
      } on Object catch (error) {
        firstError = error;
      }
    }
    if (firstError != null) {
      return RevocationCleanupFailure(
        message: firstError is Failure
            ? firstError.message
            : 'Revoked credential cleanup could not be completed.',
        cause: firstError,
      );
    }
    _volatilePendingRevocationAccountIds.remove(accountId);
    _revocationInvalidated = _volatilePendingRevocationAccountIds.isNotEmpty;
    return null;
  }

  Future<RevocationCleanupFailure?> _retryPendingRevocation() async {
    String? durablePendingRevocation;
    Set<String> journalPending = const {};
    Object? primaryReadError;
    try {
      durablePendingRevocation = await revocationStorage
          .readPendingRevocationAccountId();
    } on Object catch (error) {
      primaryReadError = error;
    }
    try {
      journalPending = await revocationJournal?.readAccountIds() ?? const {};
    } on Object catch (error) {
      return RevocationCleanupFailure(
        message: 'Pending credential revocation could not be verified.',
        cause: error,
      );
    }
    if (primaryReadError != null &&
        journalPending.isEmpty &&
        _volatilePendingRevocationAccountIds.isEmpty) {
      return RevocationCleanupFailure(
        message: 'Pending credential revocation could not be verified.',
        cause: primaryReadError,
      );
    }
    final pendingRevocations = <String>{
      ..._volatilePendingRevocationAccountIds,
      ...journalPending,
      ?durablePendingRevocation,
    };
    if (pendingRevocations.isEmpty) return null;
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
        notifyRevocation: false,
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

  Future<Failure?> _applyOwnership(OfflineOwnershipIntent intent) async {
    final coordinator = ownershipCoordinator;
    if (coordinator == null) return null;
    final report = await coordinator.apply(intent);
    if (report.completed) return null;
    return LocalStorageFailure(
      message: report.failures.map((failure) => failure.message).join(' '),
      cause: report,
    );
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
    final projectionStore = store is WriteBarrierOfflineStore
        ? (store as WriteBarrierOfflineStore).delegate
        : store;
    return projectionStore.deleteCacheNamespace(
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

final class _CachedAuthSessionTransaction implements AuthSessionTransaction {
  const _CachedAuthSessionTransaction({
    required this.session,
    required this.upstream,
    required this.rollbackProjection,
  });

  @override
  final AuthSession session;
  final AuthSessionTransaction upstream;
  final Future<void> Function() rollbackProjection;

  @override
  Future<Result<void>> commit() async {
    Result<void> result;
    try {
      result = await upstream.commit();
    } on Object catch (error) {
      result = FailureResult(
        LocalStorageFailure(
          message: 'Unable to commit the local authentication session.',
          cause: error,
        ),
      );
    }
    if (result is Success<void>) return result;
    try {
      await rollbackProjection();
      return result;
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to roll back the failed authentication session.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> abort() async {
    Result<void> upstreamResult;
    try {
      upstreamResult = await upstream.abort();
    } on Object catch (error) {
      upstreamResult = FailureResult(
        LocalStorageFailure(
          message: 'Unable to abort the local credential transaction.',
          cause: error,
        ),
      );
    }
    try {
      await rollbackProjection();
      return upstreamResult;
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to roll back the local session projection.',
          cause: error,
        ),
      );
    }
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
