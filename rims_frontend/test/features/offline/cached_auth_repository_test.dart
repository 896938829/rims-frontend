import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);

  test('authenticated network restore seeds cache with age metadata', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final repository = _repository(delegate, storage, now: now);

    expect(_sessionFrom(await repository.restoreSession()), _session);
    expect(storage.accountId, '7');
    expect(repository.lastRestoreSource, AuthSessionSource.network);
    expect(repository.lastRestoreFetchedAt, now);

    delegate.restoreResult = const FailureResult(NetworkFailure());
    final cached = _sessionFrom(await repository.restoreSession());
    expect(cached?.user.username, 'alice');
    expect(cached?.accessToken, 'token');
    expect(repository.lastRestoreSource, AuthSessionSource.cache);
    expect(repository.lastRestoreFetchedAt, now);

    final controller = AuthSessionController();
    addTearDown(controller.dispose);
    await controller.restoreSession(repository);
    expect(controller.sessionSource, AuthSessionSource.cache);
    expect(controller.sessionFetchedAt, now);
  });

  test('cached session is rejected when secure token is absent', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final repository = _repository(delegate, storage, now: now);
    await repository.restoreSession();
    storage.token = null;
    delegate.restoreResult = const FailureResult(NetworkFailure());

    final result = await repository.restoreSession();

    expect(result, isA<FailureResult<AuthSession?>>());
    expect(storage.accountId, '7');
  });

  test('cached projection is rejected on secure account mismatch', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final ownership = _RecordingOwnershipCoordinator();
    final repository = _repository(
      delegate,
      storage,
      now: now,
      ownership: ownership,
    );
    await repository.restoreSession();
    storage.accountId = '8';
    delegate.restoreResult = const FailureResult(NetworkFailure());

    final result = await repository.restoreSession();

    expect(result, isA<FailureResult<AuthSession?>>());
    expect(storage.accountId, '8');
    expect(ownership.intents, isEmpty);
  });

  test(
    'warehouse switch leaves invalidation to the ownership coordinator',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
        switchResult: const Success(_warehouse12),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final store = MemoryOfflineStore();
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _repository(
        delegate,
        storage,
        store: store,
        now: now,
        ownership: ownership,
      );
      await repository.restoreSession();
      await store.writeCache(
        CacheRecord(
          key: const CacheKey(
            accountId: '7',
            warehouseId: 11,
            namespace: 'inventory',
            entityKey: 'page=1',
          ),
          payload: const {},
          schemaVersion: 1,
          fetchedAt: now,
          expiresAt: now.add(const Duration(days: 1)),
        ),
      );

      await repository.switchCurrentWarehouse(_warehouse12);

      expect(
        ownership.intents.last.reason,
        OfflineOwnershipReason.warehouseSwitch,
      );

      expect(
        await store.readCache(
          const CacheKey(
            accountId: '7',
            warehouseId: 11,
            namespace: 'inventory',
            entityKey: 'page=1',
          ),
        ),
        isNotNull,
      );
    },
  );

  test('successful permission refresh replaces cached projection', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final ownership = _RecordingOwnershipCoordinator();
    final repository = _repository(
      delegate,
      storage,
      now: now,
      ownership: ownership,
    );
    await repository.restoreSession();
    delegate.restoreResult = const Success(_adminSession);
    await repository.restoreSession();
    delegate.restoreResult = const FailureResult(NetworkFailure());

    final cached = _sessionFrom(await repository.restoreSession());

    expect(cached?.user.roleCode, 'admin');
    expect(cached?.user.isAdmin, isTrue);
    expect(cached?.user.permissionCodes, {'document:complete'});
    expect(
      ownership.intents.map((intent) => intent.reason),
      contains(OfflineOwnershipReason.permissionRefresh),
    );
  });

  test('repository logout never bypasses the ownership coordinator', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final store = MemoryOfflineStore();
    final repository = _repository(delegate, storage, store: store, now: now);
    await repository.restoreSession();
    await store.enqueue(
      OutboxOperation(
        operationId: 'logout-operation',
        idempotencyKey: 'logout-key',
        accountId: '7',
        warehouseId: 11,
        kind: OutboxOperationKind.documentCreate,
        payload: const {},
        state: OutboxState.queued,
        createdAt: now,
        confirmedAt: now,
      ),
      const {},
    );

    await repository.logout();

    expect(
      (await store.outboxRepository.list('7') as Success).data,
      hasLength(1),
    );
    expect(storage.accountId, isNull);
  });

  test(
    'token credential expiry preserves the prior account reference for safe reauthentication',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final repository = _repository(delegate, storage, now: now);
      await repository.restoreSession();

      await repository.expireCredentials();

      expect(delegate.logoutCalls, 1);
      expect(storage.accountId, '7');
    },
  );

  test('offline login is never satisfied from an existing cache', () async {
    final delegate = _FakeAuthRepository(
      restoreResult: const Success(_session),
      loginResult: const FailureResult(NetworkFailure()),
    );
    final storage = _FakeSessionStorage(token: 'token');
    final repository = _repository(delegate, storage, now: now);
    await repository.restoreSession();

    final result = await repository.login(
      username: 'alice',
      password: 'secret',
    );

    expect(result, isA<FailureResult<AuthSession>>());
    expect(delegate.loginCalls, 1);
  });

  test(
    'authentication failure preserves owned data and secure account reference',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final store = MemoryOfflineStore();
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _repository(
        delegate,
        storage,
        store: store,
        now: now,
        ownership: ownership,
      );
      await repository.restoreSession();
      delegate.restoreResult = const FailureResult(AuthenticationFailure());

      await repository.restoreSession();

      expect(storage.accountId, '7');
      expect(
        await store.readCache(
          const CacheKey(
            accountId: '7',
            namespace: 'auth.session',
            entityKey: 'projection',
          ),
        ),
        isNotNull,
      );
      expect(
        ownership.intents.single.reason,
        OfflineOwnershipReason.tokenExpiry,
      );
    },
  );

  test(
    'authorization failure requests full revocation without direct clearing',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final store = MemoryOfflineStore();
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _repository(
        delegate,
        storage,
        store: store,
        now: now,
        ownership: ownership,
      );
      await repository.restoreSession();
      delegate.restoreResult = const FailureResult(AuthorizationFailure());

      await repository.restoreSession();

      expect(ownership.intents.last.reason, OfflineOwnershipReason.revocation);
    },
  );

  test(
    'failed revocation retains credentials so cleanup can be retried',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _repository(
        delegate,
        storage,
        now: now,
        ownership: ownership,
      );
      await repository.restoreSession();
      delegate.restoreResult = const FailureResult(AuthorizationFailure());
      ownership.failNext = true;

      final result = await repository.restoreSession();

      expect(result, isA<FailureResult<AuthSession?>>());
      expect(delegate.logoutCalls, 0);
      expect(storage.token, 'token');
      expect(storage.accountId, '7');
    },
  );

  test(
    'network restore account switch is cleaned before the new projection is exposed',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _repository(
        delegate,
        storage,
        now: now,
        ownership: ownership,
      );
      await repository.restoreSession();
      delegate.restoreResult = const Success(_secondAccountSession);

      final restored = _sessionFrom(await repository.restoreSession());

      expect(restored?.user.id, 8);
      expect(
        ownership.intents.last.reason,
        OfflineOwnershipReason.accountSwitch,
      );
      expect(ownership.intents.last.accountId, '7');
      expect(ownership.intents.last.currentAccountId, '8');
    },
  );

  test(
    'controller publishes account and warehouse ownership changes',
    () async {
      final eventBus = AppEventBus();
      final controller = AuthSessionController(eventBus: eventBus);
      addTearDown(() async {
        controller.dispose();
        await eventBus.dispose();
      });
      final accountEvent = eventBus.on<AccountOwnershipChangedEvent>().first;

      await controller.startSession(_session);

      expect((await accountEvent).currentAccountId, '7');
      final warehouseEvent = eventBus
          .on<WarehouseOwnershipChangedEvent>()
          .first;
      await controller.switchWarehouse(
        authRepository: _FakeAuthRepository(
          restoreResult: const Success(_session),
          switchResult: const Success(_warehouse12),
        ),
        warehouse: _warehouse12,
      );
      final event = await warehouseEvent;
      expect(event.previousWarehouseId, 11);
      expect(event.currentWarehouseId, 12);
    },
  );

  test(
    'controller does not expose a switched account until ownership cleanup completes',
    () async {
      final ownership = _RecordingOwnershipCoordinator();
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      await controller.startSession(_session);
      final blocker = Completer<void>();
      ownership.blocker = blocker;

      final switching = controller.startSession(_secondAccountSession);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentUser?.id, 7);
      expect(controller.isOwnershipTransitioning, isTrue);
      expect(controller.canAccessOfflineData, isFalse);
      blocker.complete();
      expect(await switching, isTrue);
      expect(controller.currentUser?.id, 8);
    },
  );

  test(
    'controller keeps the prior account active when account cleanup fails',
    () async {
      final ownership = _RecordingOwnershipCoordinator();
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      await controller.startSession(_session);
      ownership.failNext = true;

      final switched = await controller.startSession(_secondAccountSession);

      expect(switched, isFalse);
      expect(controller.currentUser?.id, 7);
      expect(controller.ownershipFailure, isNotNull);
    },
  );

  test(
    'controller distinguishes logout retention, token expiry, warehouse, and permission reasons',
    () async {
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _FakeAuthRepository(
        restoreResult: const Success(_adminSession),
        switchResult: const Success(_warehouse12),
      );
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      await controller.startSession(_session);

      await controller.refreshSession(repository);
      await controller.switchWarehouse(
        authRepository: repository,
        warehouse: _warehouse12,
      );
      await controller.expireSession(authRepository: repository);

      expect(
        ownership.intents.map((intent) => intent.reason),
        containsAllInOrder([
          OfflineOwnershipReason.reauthenticated,
          OfflineOwnershipReason.permissionRefresh,
          OfflineOwnershipReason.warehouseSwitch,
          OfflineOwnershipReason.tokenExpiry,
        ]),
      );

      await controller.startSession(_session);
      await controller.logout(
        authRepository: repository,
        draftRetention: DraftRetentionChoice.retainLocally,
      );
      expect(ownership.intents.last.reason, OfflineOwnershipReason.logout);
      expect(
        ownership.intents.last.draftRetention,
        DraftRetentionChoice.retainLocally,
      );
    },
  );
}

CachedAuthRepository _repository(
  _FakeAuthRepository delegate,
  _FakeSessionStorage storage, {
  MemoryOfflineStore? store,
  OfflineOwnershipCoordinator? ownership,
  required DateTime now,
}) {
  return CachedAuthRepository(
    delegate: delegate,
    store: store ?? MemoryOfflineStore(),
    tokenStorage: storage,
    accountStorage: storage,
    ownershipCoordinator: ownership,
    now: () => now,
  );
}

final class _RecordingOwnershipCoordinator
    implements OfflineOwnershipCoordinator {
  final List<OfflineOwnershipIntent> intents = [];
  Completer<void>? blocker;
  bool failNext = false;

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    intents.add(intent);
    final activeBlocker = blocker;
    if (activeBlocker != null) {
      await activeBlocker.future;
      blocker = null;
    }
    final shouldFail = failNext;
    failNext = false;
    return OfflineOwnershipReport(
      reason: intent.reason,
      accountId: intent.accountId,
      executedCounts: const OfflineOwnershipCounts(),
      failures: shouldFail
          ? const [
              OfflineOwnershipFailure(
                step: OfflineOwnershipStep.store,
                message: 'cleanup failed',
              ),
            ]
          : const [],
    );
  }

  @override
  bool canAccessOfflineData(String accountId) => true;

  @override
  bool canSync(String accountId) => true;
}

AuthSession? _sessionFrom(Result<AuthSession?> result) {
  return result.when(
    success: (session) => session,
    failure: (failure) => throw TestFailure('Expected session: $failure'),
  );
}

final class _FakeSessionStorage
    implements TokenStorage, AuthenticatedAccountStorage {
  _FakeSessionStorage({this.token});

  String? token;
  String? accountId;

  @override
  Future<void> clearAccessToken() async => token = null;

  @override
  Future<String?> readAccessToken() async => token;

  @override
  Future<void> saveAccessToken(String token) async => this.token = token;

  @override
  Future<void> clearAuthenticatedAccountId() async => accountId = null;

  @override
  Future<String?> readAuthenticatedAccountId() async => accountId;

  @override
  Future<void> saveAuthenticatedAccountId(String accountId) async {
    this.accountId = accountId;
  }
}

final class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({
    required this.restoreResult,
    this.loginResult = const FailureResult(UnknownFailure()),
    this.switchResult = const FailureResult(UnknownFailure()),
  });

  Result<AuthSession?> restoreResult;
  Result<AuthSession> loginResult;
  Result<Warehouse> switchResult;
  int loginCalls = 0;
  int logoutCalls = 0;

  @override
  Future<Result<AuthSession?>> restoreSession() async => restoreResult;

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    loginCalls += 1;
    return loginResult;
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    return switchResult;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }
}

const _warehouse11 = Warehouse(
  id: 11,
  code: 'SH',
  name: '上海仓',
  isDefault: true,
);
const _warehouse12 = Warehouse(
  id: 12,
  code: 'BJ',
  name: '北京仓',
  isDefault: false,
);
const _user = AppUser(
  id: 7,
  username: 'alice',
  realName: 'Alice',
  roleCode: 'user',
  roleName: '普通用户',
);
const _admin = AppUser(
  id: 7,
  username: 'alice',
  realName: 'Alice',
  roleCode: 'admin',
  roleName: '管理员',
  permissionCodes: {'document:complete'},
);
const _session = AuthSession(
  accessToken: 'token',
  user: _user,
  currentWarehouse: _warehouse11,
  warehouses: [_warehouse11, _warehouse12],
);
const _adminSession = AuthSession(
  accessToken: 'token',
  user: _admin,
  currentWarehouse: _warehouse11,
  warehouses: [_warehouse11, _warehouse12],
);

const _secondAccountSession = AuthSession(
  accessToken: 'token-8',
  user: AppUser(
    id: 8,
    username: 'bob',
    realName: 'Bob',
    roleCode: 'user',
    roleName: '普通用户',
  ),
  currentWarehouse: _warehouse12,
  warehouses: [_warehouse12],
);
