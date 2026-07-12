import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/auth_session.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../auth/domain/repositories/auth_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../services/cache_policy.dart';

final class CachedAuthRepository
    implements AuthRepository, AuthSessionRestoreMetadata {
  CachedAuthRepository({
    required this.delegate,
    required this.store,
    required this.tokenStorage,
    required this.accountStorage,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  static const String _namespace = 'auth.session';
  static const String _entityKey = 'projection';

  final AuthRepository delegate;
  final OfflineStore store;
  final TokenStorage tokenStorage;
  final AuthenticatedAccountStorage accountStorage;
  final DateTime Function() now;

  @override
  AuthSessionSource? lastRestoreSource;

  @override
  DateTime? lastRestoreFetchedAt;

  @override
  DateTime? lastRestoreExpiresAt;

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    _clearMetadata();
    final token = (await tokenStorage.readAccessToken())?.trim();
    final accountId = await accountStorage.readAuthenticatedAccountId();
    if (token == null || token.isEmpty) {
      await _clearAccount(accountId);
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
      await _clearAccount(previousAccountId);
      return const Success(null);
    }
    final accountId = session.user.id.toString();
    if (previousAccountId != null && previousAccountId != accountId) {
      await _clearAccount(previousAccountId);
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
      await _clearAccount(accountId);
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
      await _clearAccount(accountId);
      return FailureResult(failure);
    }
    if (!CachePolicy.references.canFallbackTo(record, now())) {
      return FailureResult(failure);
    }
    try {
      final session = _decodeSession(record.payload, token);
      if (session.user.id.toString() != accountId) {
        await _clearAccount(accountId);
        return FailureResult(failure);
      }
      lastRestoreSource = AuthSessionSource.cache;
      lastRestoreFetchedAt = record.fetchedAt;
      lastRestoreExpiresAt = record.expiresAt;
      return Success(session);
    } on Object {
      await _clearAccount(accountId);
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
            if (previousWarehouseId != null &&
                previousWarehouseId != confirmed.id) {
              await store.invalidateWarehouseCache(
                accountId: accountId,
                warehouseId: previousWarehouseId,
              );
            }
          } on Object {
            await store.clearAccount(accountId);
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
    await _clearAccount(accountId);
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

  Future<void> _clearAccount(String? accountId) async {
    if (accountId != null) await store.clearAccount(accountId);
    await accountStorage.clearAuthenticatedAccountId();
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
