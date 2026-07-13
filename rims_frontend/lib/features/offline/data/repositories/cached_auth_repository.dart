import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/auth_session.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../auth/domain/repositories/auth_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../services/cache_policy.dart';

final class CachedAuthRepository
    implements
        AuthRepository,
        AuthSessionRestoreMetadata,
        AuthCredentialInvalidator {
  CachedAuthRepository({
    required this.delegate,
    required this.store,
    required this.tokenStorage,
    required this.accountStorage,
    required this.revocationStorage,
    required this.onSessionRevoked,
    this.ownershipCoordinator,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  static const String _namespace = 'auth.session';
  static const String _entityKey = 'projection';

  final AuthRepository delegate;
  final OfflineStore store;
  final TokenStorage tokenStorage;
  final AuthenticatedAccountStorage accountStorage;
  final PendingRevocationStorage revocationStorage;
  final OfflineOwnershipCoordinator? ownershipCoordinator;
  final void Function() onSessionRevoked;
  final DateTime Function() now;
  String? _volatilePendingRevocationAccountId;
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
          _revocationInvalidated || _volatilePendingRevocationAccountId != null
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
    _clearMetadata();
    final pendingRevocation =
        await revocationStorage.readPendingRevocationAccountId() ??
        _volatilePendingRevocationAccountId;
    if (pendingRevocation != null) {
      final failure = await _completeRevocation(
        pendingRevocation,
        persistMarker: false,
      );
      if (failure != null) return FailureResult(failure);
    }
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
      ),
      FailureResult<AuthSession?>(failure: final failure) =>
        _handleRestoreFailure(failure, token: token, accountId: accountId),
    };
  }

  Future<Result<AuthSession?>> _handleNetworkRestore(
    AuthSession? session, {
    required String? previousAccountId,
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
    final record = await _writeSession(session);
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
    if (failure is AuthenticationFailure || failure is AuthorizationFailure) {
      if (accountId != null) {
        if (failure is AuthorizationFailure) {
          final revocationFailure = await _completeRevocation(
            accountId,
            persistMarker: true,
          );
          if (revocationFailure != null) {
            return FailureResult(revocationFailure);
          }
        } else {
          final ownershipFailure = await _applyOwnership(
            OfflineOwnershipIntent.tokenExpiry(accountId: accountId),
          );
          if (ownershipFailure != null) {
            return FailureResult(ownershipFailure);
          }
        }
        if (failure is AuthorizationFailure) {
          return FailureResult(failure);
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
    final result = await delegate.login(username: username, password: password);
    if (result case Success<AuthSession>(:final data)) {
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
          await delegate.logout();
          return FailureResult(ownershipFailure);
        }
      }
      final reauthenticationFailure = await _applyOwnership(
        OfflineOwnershipIntent.reauthenticated(accountId: accountId),
      );
      if (reauthenticationFailure != null) {
        await delegate.logout();
        return FailureResult(reauthenticationFailure);
      }
      await _writeSession(data);
    }
    return result;
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    final result = await delegate.switchCurrentWarehouse(warehouse);
    if (result case Success<Warehouse>(data: final confirmed)) {
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
            await _writeSession(updated);
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

  Future<CacheRecord> _writeSession(AuthSession session) async {
    final fetchedAt = now().toUtc();
    final accountId = session.user.id.toString();
    final record = CacheRecord(
      key: _cacheKey(accountId),
      payload: _encodeSession(session),
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
    await accountStorage.saveAuthenticatedAccountId(accountId);
    return record;
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
    required bool persistMarker,
  }) async {
    _volatilePendingRevocationAccountId = accountId;
    _revocationInvalidated = true;
    onSessionRevoked();
    Object? firstError;
    if (persistMarker) {
      try {
        await revocationStorage.savePendingRevocationAccountId(accountId);
      } on Object catch (error) {
        firstError = error;
      }
    }
    try {
      await _expireDelegateCredentials();
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
        await revocationStorage.clearPendingRevocationAccountId();
      } on Object catch (error) {
        firstError = error;
      }
      try {
        await accountStorage.clearAuthenticatedAccountId();
      } on Object catch (error) {
        firstError ??= error;
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
    _volatilePendingRevocationAccountId = null;
    _revocationInvalidated = false;
    return null;
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
