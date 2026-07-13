import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/core/storage/pending_revocation_journal.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);

  test(
    'real 403 remains revocation when secure token clearing fails',
    () async {
      final storage = _FakeSessionStorage(token: 'revoked-token');
      final remote = _MutableAuthRemoteDataSource(
        currentUserResult: const Success(
          AppUserModel(
            id: 7,
            username: 'alice',
            realName: 'Alice',
            roleCode: 'user',
            roleName: '普通用户',
          ),
        ),
        warehousesResult: const Success([
          WarehouseModel(id: 11, code: 'SH', name: '上海仓', isDefault: true),
        ]),
      );
      final keys = MemoryOfflineDatabaseKeyManager();
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopOwnedFiles(),
        scans: const _NoopOwnedScans(),
        reviews: const _NoopReviewInvalidator(),
        databaseKeys: keys,
      );
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      final delegate = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: storage,
      );
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        ownershipCoordinator: ownership,
        onSessionRevoked: controller.invalidateRevokedSession,
        now: () => now,
      );
      await controller.restoreSession(repository);
      expect(controller.session?.user.id, 7);
      remote.currentUserResult = const FailureResult(
        AuthorizationFailure(statusCode: 403),
      );
      storage.failNext(_RevocationStorageFailure.clearCredential);

      await controller.refreshSession(repository);

      expect(controller.session, isNull);
      expect(controller.canAuthenticateRequests, isFalse);
      expect(controller.restoreFailure, isA<RevocationCleanupFailure>());
      expect(storage.pendingRevocationAccountId, '7');
      expect(keys.generation, 1);
      expect(ownership.canSync('7'), isFalse);

      await controller.refreshSession(repository);

      expect(controller.restoreFailure, isNull);
      expect(storage.pendingRevocationAccountId, isNull);
      expect(keys.generation, 2);
    },
  );

  for (final stage in _AuthenticationFailureStage.values) {
    test(
      'real ${stage.name} 401 invalidates memory before retryable credential cleanup',
      () async {
        final storage = _FakeSessionStorage(token: 'expired-token');
        final remote = _MutableAuthRemoteDataSource(
          currentUserResult: const Success(
            AppUserModel(
              id: 7,
              username: 'alice',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const Success([
            WarehouseModel(id: 11, code: 'SH', name: '上海仓', isDefault: true),
          ]),
        );
        final store = MemoryOfflineStore();
        final reviews = _BlockingReviewInvalidator();
        final ownership = OfflineOwnershipService(
          store: store,
          files: const _NoopOwnedFiles(),
          scans: const _NoopOwnedScans(),
          reviews: reviews,
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
        );
        final controller = AuthSessionController(
          ownershipCoordinator: ownership,
        );
        addTearDown(controller.dispose);
        final delegate = AuthRepositoryImpl(
          remoteDataSource: remote,
          secureStorage: storage,
        );
        final repository = CachedAuthRepository(
          delegate: delegate,
          store: store,
          tokenStorage: storage,
          accountStorage: storage,
          revocationStorage: storage,
          ownershipCoordinator: ownership,
          onSessionRevoked: controller.invalidateRevokedSession,
          onSessionExpired: controller.invalidateExpiredSession,
          now: () => now,
        );
        await controller.restoreSession(repository);
        await store.saveDraft(
          DocumentDraft(
            id: 'retained-draft',
            accountId: '7',
            warehouseId: 11,
            payload: const {},
            createdAt: now,
            updatedAt: now,
          ),
        );
        switch (stage) {
          case _AuthenticationFailureStage.currentUser:
            remote.currentUserResult = const FailureResult(
              AuthenticationFailure(statusCode: 401),
            );
          case _AuthenticationFailureStage.warehouses:
            remote.warehousesResult = const FailureResult(
              AuthenticationFailure(statusCode: 401),
            );
        }
        storage.failNext(_RevocationStorageFailure.clearCredential, times: 2);

        final refresh = controller.refreshSession(repository);
        await reviews.firstInvalidationStarted.future;

        expect(controller.session, isNull);
        expect(controller.accessToken, isNull);
        expect(controller.canAuthenticateRequests, isFalse);
        expect(controller.isRestoring, isTrue);
        expect(ownership.canSync('7'), isFalse);

        reviews.releaseFirstInvalidation.complete();
        await refresh;

        expect(controller.isRestoring, isFalse);
        expect(controller.restoreFailure, isA<AuthenticationFailure>());
        expect(controller.restoreFailure?.cause, isA<LocalStorageFailure>());
        expect(storage.token, 'expired-token');
        expect((await store.inspectAccount('7')).drafts, 1);

        await controller.refreshSession(repository);

        expect(controller.session, isNull);
        expect(controller.canAuthenticateRequests, isFalse);
        expect(controller.restoreFailure, isA<AuthenticationFailure>());
        expect(storage.token, isNull);
        expect(reviews.invalidationCalls, 2);
        expect((await store.inspectAccount('7')).drafts, 1);
      },
    );
  }

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
    'failed revocation discards credentials and retains a secure retry marker',
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
      expect(delegate.logoutCalls, 1);
      expect(storage.token, isNull);
      expect(storage.accountId, isNull);
      expect(storage.pendingRevocationAccountId, '7');
    },
  );

  test('fallback revocation journal survives primary marker failure', () async {
    final storage = _FakeSessionStorage(token: 'revoked-token')
      ..accountId = '7'
      ..failNext(_RevocationStorageFailure.saveMarker);
    final journal = MemoryPendingRevocationJournal();
    final firstOwnership = _RecordingOwnershipCoordinator()..failNext = true;
    final first = CachedAuthRepository(
      delegate: _FakeAuthRepository(
        restoreResult: const FailureResult(AuthorizationFailure()),
      ),
      store: MemoryOfflineStore(),
      tokenStorage: storage,
      accountStorage: storage,
      revocationStorage: storage,
      revocationJournal: journal,
      ownershipCoordinator: firstOwnership,
      onSessionRevoked: () {},
    );

    expect(await first.restoreSession(), isA<FailureResult<AuthSession?>>());
    expect(storage.token, isNull);
    expect(storage.accountId, isNull);
    expect(await journal.readAccountIds(), {'7'});

    final loginDelegate = _FakeAuthRepository(
      restoreResult: const Success<AuthSession?>(null),
      loginResult: const Success(_session),
    );
    final restartedOwnership = _RecordingOwnershipCoordinator()
      ..failNext = true;
    final restarted = CachedAuthRepository(
      delegate: loginDelegate,
      store: MemoryOfflineStore(),
      tokenStorage: storage,
      accountStorage: storage,
      revocationStorage: storage,
      revocationJournal: journal,
      ownershipCoordinator: restartedOwnership,
      onSessionRevoked: () {},
    );
    expect(
      await restarted.login(username: 'alice', password: 'secret'),
      isA<FailureResult<AuthSession>>(),
    );
    expect(loginDelegate.loginCalls, 0);
    expect(await journal.readAccountIds(), {'7'});

    expect(
      await restarted.login(username: 'alice', password: 'secret'),
      isA<Success<AuthSession>>(),
    );
    expect(loginDelegate.loginCalls, 1);
    expect(await journal.readAccountIds(), isEmpty);
  });

  test(
    'pending revocations are retried per account without clearing later failures',
    () async {
      final storage = _FakeSessionStorage()..pendingRevocationAccountId = '7';
      final journal = MemoryPendingRevocationJournal();
      await journal.addAccountId('7');
      await journal.addAccountId('8');
      final delegate = _FakeAuthRepository(
        restoreResult: const Success<AuthSession?>(null),
        loginResult: const Success(_session),
      );
      final ownership = _AccountFailingOwnershipCoordinator({'8'});
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        revocationJournal: journal,
        ownershipCoordinator: ownership,
        onSessionRevoked: () {},
      );

      final first = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(first, isA<FailureResult<AuthSession>>());
      expect(delegate.loginCalls, 0);
      expect(await journal.readAccountIds(), {'8'});
      expect(storage.pendingRevocationAccountId, '8');

      final restartedDelegate = _FakeAuthRepository(
        restoreResult: const Success<AuthSession?>(null),
        loginResult: const Success(_session),
      );
      final restarted = CachedAuthRepository(
        delegate: restartedDelegate,
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        revocationJournal: journal,
        ownershipCoordinator: _AccountFailingOwnershipCoordinator({}),
        onSessionRevoked: () {},
      );

      expect(
        await restarted.login(username: 'alice', password: 'secret'),
        isA<Success<AuthSession>>(),
      );
      expect(restartedDelegate.loginCalls, 1);
      expect(await journal.readAccountIds(), isEmpty);
      expect(storage.pendingRevocationAccountId, isNull);
    },
  );

  test(
    'pending revocation journal mutations do not lose another account',
    () async {
      final journal = MemoryPendingRevocationJournal();

      await Future.wait([
        journal.addAccountId('7'),
        journal.addAccountId('8'),
        journal.removeAccountId('7'),
      ]);

      expect(await journal.readAccountIds(), {'8'});
    },
  );

  test(
    'shared preferences revocation journal serializes concurrent mutations',
    () async {
      final previousPlatform = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      addTearDown(
        () => SharedPreferencesAsyncPlatform.instance = previousPlatform,
      );
      final journal = SharedPreferencesPendingRevocationJournal();

      await Future.wait([
        journal.addAccountId('7'),
        journal.addAccountId('8'),
        journal.removeAccountId('7'),
      ]);

      final restarted = SharedPreferencesPendingRevocationJournal();
      expect(await restarted.readAccountIds(), {'8'});
    },
  );

  test('stale login rolls back only its own durable token', () async {
    var epoch = 0;
    final storage = _FakeSessionStorage();
    final delegate = _ConcurrentLoginAuthRepository(storage);
    final owners = ['owner-a', 'owner-b'].iterator;
    final repository = CachedAuthRepository(
      delegate: delegate,
      store: MemoryOfflineStore(),
      tokenStorage: storage,
      accountStorage: storage,
      revocationStorage: storage,
      ownershipCoordinator: _RecordingOwnershipCoordinator(),
      authEpochReader: () => epoch,
      authTransactionOwnerFactory: () {
        owners.moveNext();
        return owners.current;
      },
      onSessionRevoked: () {},
    );
    final stale = repository.login(username: 'alice', password: 'secret');
    await delegate.aliceStarted.future;
    epoch += 1;

    final current = await repository.login(username: 'bob', password: 'secret');
    delegate.releaseAlice.complete();
    final staleResult = await stale;

    expect(current, isA<Success<AuthSession>>());
    expect(staleResult, isA<FailureResult<AuthSession>>());
    expect(storage.token, 'token');
    expect(storage.tokenOwnerId, 'owner-b');
    expect(storage.ownerClearAttempts, ['owner-a']);
  });

  test(
    'failed newer login cannot leave the stale login token durable',
    () async {
      var epoch = 0;
      final storage = _FakeSessionStorage();
      final delegate = _ConcurrentLoginAuthRepository(storage)..bobFails = true;
      final owners = ['owner-a', 'owner-b'].iterator;
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        ownershipCoordinator: _RecordingOwnershipCoordinator(),
        authEpochReader: () => epoch,
        authTransactionOwnerFactory: () {
          owners.moveNext();
          return owners.current;
        },
        onSessionRevoked: () {},
      );
      final stale = repository.login(username: 'alice', password: 'secret');
      await delegate.aliceStarted.future;
      epoch += 1;

      expect(
        await repository.login(username: 'bob', password: 'secret'),
        isA<FailureResult<AuthSession>>(),
      );
      delegate.releaseAlice.complete();
      expect(await stale, isA<FailureResult<AuthSession>>());

      expect(storage.token, isNull);
      expect(storage.ownerClearAttempts, ['owner-a']);
      final restarted = CachedAuthRepository(
        delegate: _FakeAuthRepository(
          restoreResult: const Success<AuthSession?>(null),
        ),
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
      );
      expect(
        await restarted.restoreSession(),
        const Success<AuthSession?>(null),
      );
    },
  );

  for (final newerBootstrapFails in [false, true]) {
    test('real auth layering keeps equal-token owners isolated when newer '
        'bootstrap ${newerBootstrapFails ? 'fails' : 'succeeds'}', () async {
      var epoch = 0;
      final storage = _FakeSessionStorage();
      final remote = _ConcurrentSameTokenRemoteDataSource(
        newerBootstrapFails: newerBootstrapFails,
      );
      final delegate = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: storage,
      );
      final owners = ['owner-a', 'owner-b'].iterator;
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        ownershipCoordinator: _RecordingOwnershipCoordinator(),
        authEpochReader: () => epoch,
        authTransactionOwnerFactory: () {
          owners.moveNext();
          return owners.current;
        },
        onSessionRevoked: () {},
      );
      final stale = repository.login(username: 'alice', password: 'secret');
      await remote.firstWarehouseStarted.future;
      epoch += 1;

      final current = await repository.login(
        username: 'bob',
        password: 'secret',
      );
      remote.releaseFirstWarehouse.complete();
      expect(await stale, isA<FailureResult<AuthSession>>());

      if (newerBootstrapFails) {
        expect(current, isA<FailureResult<AuthSession>>());
        expect(storage.token, isNull);
        expect(storage.ownerClearAttempts, ['owner-b', 'owner-a']);
      } else {
        expect(current, isA<Success<AuthSession>>());
        expect(storage.token, 'token');
        expect(storage.tokenOwnerId, 'owner-b');
        expect(storage.ownerClearAttempts, ['owner-a']);
      }
    });
  }

  test(
    'cached login commits its pending token only after ownership and projection',
    () async {
      final storage = _FakeSessionStorage();
      final rawStore = MemoryOfflineStore();
      final ownership = _RecordingOwnershipCoordinator()
        ..blocker = Completer<void>();
      final delegate = _ConcurrentLoginAuthRepository(storage);
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: rawStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        ownershipCoordinator: ownership,
        authTransactionOwnerFactory: () => 'cached-owner',
        onSessionRevoked: () {},
      );

      final login = repository.login(username: 'bob', password: 'secret');
      while (ownership.intents.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(storage.token, 'token');
      expect(await storage.readAccessToken(), isNull);
      expect(storage.accountId, isNull);
      expect((await rawStore.inspectAccount('8')).cacheEntries, 0);

      ownership.blocker!.complete();
      expect(await login, isA<Success<AuthSession>>());
      expect(await storage.readAccessToken(), 'token');
      expect(storage.committedOwnerIds, ['cached-owner']);
      expect(storage.accountId, '8');
      expect((await rawStore.inspectAccount('8')).cacheEntries, 1);
    },
  );

  test(
    'cached commit failure remains unauthenticated across restart',
    () async {
      final storage = _FakeSessionStorage()..failTokenCommits = true;
      final rawStore = MemoryOfflineStore();
      final repository = CachedAuthRepository(
        delegate: _ConcurrentLoginAuthRepository(storage),
        store: rawStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        ownershipCoordinator: _RecordingOwnershipCoordinator(),
        authTransactionOwnerFactory: () => 'cached-owner',
        onSessionRevoked: () {},
      );

      final result = await repository.login(
        username: 'bob',
        password: 'secret',
      );

      expect(
        result.when(success: (_) => null, failure: (failure) => failure),
        isA<LocalStorageFailure>(),
      );
      expect(await storage.readAccessToken(), isNull);
      expect(storage.accountId, isNull);
      expect((await rawStore.inspectAccount('8')).cacheEntries, 0);

      storage.failTokenCommits = false;
      final restarted = CachedAuthRepository(
        delegate: _FakeAuthRepository(
          restoreResult: const Success<AuthSession?>(null),
        ),
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
      );
      expect(
        await restarted.restoreSession(),
        const Success<AuthSession?>(null),
      );
      expect(storage.token, isNull);
    },
  );

  test(
    'switch token storage exception is returned as LocalStorageFailure',
    () async {
      final storage = _FakeSessionStorage(token: 'token')
        ..accountId = '7'
        ..tokenReadError = StateError('secure read failed');
      final repository = CachedAuthRepository(
        delegate: _FakeAuthRepository(
          restoreResult: const Success<AuthSession?>(null),
          switchResult: const Success(
            Warehouse(
              id: 2,
              code: 'WH2',
              name: 'Warehouse 2',
              isDefault: false,
            ),
          ),
        ),
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
      );

      final result = await repository.switchCurrentWarehouse(
        const Warehouse(
          id: 2,
          code: 'WH2',
          name: 'Warehouse 2',
          isDefault: false,
        ),
      );

      expect(
        result.when(success: (_) => null, failure: (failure) => failure),
        isA<LocalStorageFailure>(),
      );
    },
  );

  test(
    'revocation keeps the durable marker until account metadata is cleared',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final repository = _repository(delegate, storage, now: now);
      await repository.restoreSession();
      delegate.restoreResult = const FailureResult(AuthorizationFailure());
      storage.failNext(_RevocationStorageFailure.clearAccount);

      final result = await repository.restoreSession();

      expect(result, isA<FailureResult<AuthSession?>>());
      expect(storage.accountId, '7');
      expect(storage.pendingRevocationAccountId, '7');
    },
  );

  test(
    '403 refresh invalidates request credentials before failed cleanup and retries without the revoked token',
    () async {
      final delegate = _FakeAuthRepository(
        restoreResult: const Success(_session),
      );
      final storage = _FakeSessionStorage(token: 'token');
      final ownership = _RecordingOwnershipCoordinator();
      final controller = AuthSessionController();
      addTearDown(controller.dispose);
      final repository = _repository(
        delegate,
        storage,
        now: now,
        ownership: ownership,
        onSessionRevoked: controller.invalidateRevokedSession,
      );
      await repository.restoreSession();
      await controller.startSession(_session);
      delegate.restoreResult = const FailureResult(AuthorizationFailure());
      ownership.blocker = Completer<void>();
      ownership.failNext = true;

      final refresh = controller.refreshSession(repository);
      while (ownership.intents
          .where((intent) => intent.reason == OfflineOwnershipReason.revocation)
          .isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.session, isNull);
      expect(controller.canAuthenticateRequests, isFalse);
      expect(
        controller.canAuthenticateRequests
            ? controller.accessToken ?? await storage.readAccessToken()
            : null,
        isNull,
      );
      expect(storage.pendingRevocationAccountId, '7');

      ownership.blocker!.complete();
      await refresh;
      expect(controller.restoreFailure, isA<RevocationCleanupFailure>());
      expect(storage.token, isNull);
      expect(storage.accountId, isNull);

      delegate.restoreResult = const Success<AuthSession?>(null);
      final retried = await repository.restoreSession();
      expect(retried, const Success<AuthSession?>(null));
      expect(
        ownership.intents
            .where(
              (intent) => intent.reason == OfflineOwnershipReason.revocation,
            )
            .length,
        2,
      );
      expect(storage.pendingRevocationAccountId, isNull);
      expect(storage.accountId, isNull);
    },
  );

  for (final storageFailure in _RevocationStorageFailure.values) {
    test(
      'revocation ${storageFailure.name} failure never leaves restore busy or the old token usable',
      () async {
        final delegate = _FakeAuthRepository(
          restoreResult: const Success(_session),
        );
        final storage = _FakeSessionStorage(token: 'token');
        final ownership = _RecordingOwnershipCoordinator();
        final controller = AuthSessionController();
        addTearDown(controller.dispose);
        final repository = _repository(
          delegate,
          storage,
          now: now,
          ownership: ownership,
          onSessionRevoked: controller.invalidateRevokedSession,
        );
        await repository.restoreSession();
        await controller.startSession(_session);
        delegate.restoreResult = const FailureResult(AuthorizationFailure());
        storage.failNext(storageFailure);

        await controller.refreshSession(repository);

        expect(controller.isRestoring, isFalse);
        expect(controller.session, isNull);
        expect(controller.accessToken, isNull);
        expect(controller.canAuthenticateRequests, isFalse);
        expect(controller.restoreFailure, isA<Failure>());
        expect(controller.restoreFailure, isNot(isA<UnknownFailure>()));

        delegate.restoreResult = const Success<AuthSession?>(null);
        await controller.refreshSession(repository);

        expect(controller.isRestoring, isFalse);
        expect(controller.restoreFailure, isNull);
        expect(storage.token, isNull);
        expect(storage.pendingRevocationAccountId, isNull);
        expect(
          ownership.intents
              .where(
                (intent) => intent.reason == OfflineOwnershipReason.revocation,
              )
              .length,
          greaterThanOrEqualTo(2),
        );
      },
    );
  }

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
    'controller drops the in-memory session when refresh is forbidden',
    () async {
      final repository = _FakeAuthRepository(
        restoreResult: const FailureResult(AuthorizationFailure()),
      );
      final controller = AuthSessionController();
      addTearDown(controller.dispose);
      await controller.startSession(_session);

      await controller.refreshSession(repository);

      expect(controller.session, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.restoreFailure, isA<AuthorizationFailure>());
    },
  );

  test(
    'token expiry invalidates memory before credential cleanup and contains storage errors',
    () async {
      final ownership = _RecordingOwnershipCoordinator();
      final repository = _ThrowingCredentialRepository();
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      await controller.startSession(_session);

      final expiry = controller.expireSession(authRepository: repository);

      expect(controller.session, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.canAuthenticateRequests, isFalse);
      expect(controller.isOwnershipTransitioning, isTrue);
      await expiry;
      expect(controller.isOwnershipTransitioning, isFalse);
      expect(controller.restoreFailure, isA<LocalStorageFailure>());

      repository.failExpiry = false;
      final login = await repository.login(
        username: 'alice',
        password: 'secret',
      );
      expect(login, isA<Success<AuthSession>>());
      expect(
        await controller.startSession((login as Success<AuthSession>).data),
        isTrue,
      );
      expect(controller.canAuthenticateRequests, isTrue);
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
  void Function()? onSessionRevoked,
  required DateTime now,
}) {
  return CachedAuthRepository(
    delegate: delegate,
    store: store ?? MemoryOfflineStore(),
    tokenStorage: storage,
    accountStorage: storage,
    revocationStorage: storage,
    ownershipCoordinator: ownership,
    onSessionRevoked: onSessionRevoked ?? () {},
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

final class _AccountFailingOwnershipCoordinator
    implements OfflineOwnershipCoordinator {
  _AccountFailingOwnershipCoordinator(this.failRevocationsFor);

  final Set<String> failRevocationsFor;

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    final fails =
        intent.reason == OfflineOwnershipReason.revocation &&
        failRevocationsFor.contains(intent.accountId);
    return OfflineOwnershipReport(
      reason: intent.reason,
      accountId: intent.accountId,
      executedCounts: const OfflineOwnershipCounts(),
      failures: fails
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
    implements
        TokenStorage,
        ConditionalTokenStorage,
        AuthTokenTransactionStorage,
        AuthenticatedAccountStorage,
        PendingRevocationStorage,
        ConditionalPendingRevocationStorage {
  _FakeSessionStorage({this.token}) : tokenCommitted = token != null;

  String? token;
  String? tokenOwnerId;
  bool tokenCommitted;
  bool failTokenCommits = false;
  Object? tokenReadError;
  final List<String> committedOwnerIds = [];
  String? accountId;
  String? pendingRevocationAccountId;
  final Map<_RevocationStorageFailure, int> _remainingFailures = {};
  final List<String> conditionalClearAttempts = [];
  final List<String> ownerClearAttempts = [];

  void failNext(_RevocationStorageFailure failure, {int times = 1}) {
    _remainingFailures[failure] = times;
  }

  void _throwIf(_RevocationStorageFailure failure) {
    final remaining = _remainingFailures[failure] ?? 0;
    if (remaining == 0) return;
    if (remaining == 1) {
      _remainingFailures.remove(failure);
    } else {
      _remainingFailures[failure] = remaining - 1;
    }
    throw StateError('${failure.name} failed');
  }

  @override
  Future<void> clearAccessToken() async {
    _throwIf(_RevocationStorageFailure.clearCredential);
    token = null;
    tokenOwnerId = null;
    tokenCommitted = false;
  }

  @override
  Future<bool> clearAccessTokenIfMatches(String expectedToken) async {
    conditionalClearAttempts.add(expectedToken);
    if (token != expectedToken) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> clearAccessTokenForOwner(String ownerId) async {
    ownerClearAttempts.add(ownerId);
    if (tokenOwnerId != ownerId) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> clearPendingAccessToken() async {
    if (token == null || tokenCommitted) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> commitAccessTokenForOwner(String ownerId) async {
    if (failTokenCommits) throw StateError('token commit failed');
    if (tokenOwnerId != ownerId || token == null) return false;
    tokenCommitted = true;
    committedOwnerIds.add(ownerId);
    return true;
  }

  @override
  Future<String?> readAccessToken() async {
    if (tokenReadError case final error?) throw error;
    return tokenCommitted ? token : null;
  }

  @override
  Future<void> saveAccessToken(String token) async {
    this.token = token;
    tokenOwnerId = null;
    tokenCommitted = true;
  }

  @override
  Future<void> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
  }) async {
    this.token = token;
    tokenOwnerId = ownerId;
    tokenCommitted = false;
  }

  @override
  Future<void> clearAuthenticatedAccountId() async {
    _throwIf(_RevocationStorageFailure.clearAccount);
    accountId = null;
  }

  @override
  Future<String?> readAuthenticatedAccountId() async => accountId;

  @override
  Future<void> saveAuthenticatedAccountId(String accountId) async {
    this.accountId = accountId;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    _throwIf(_RevocationStorageFailure.clearMarker);
    pendingRevocationAccountId = null;
  }

  @override
  Future<bool> clearPendingRevocationAccountIdIfMatches(
    String expectedAccountId,
  ) async {
    if (pendingRevocationAccountId != expectedAccountId) return false;
    await clearPendingRevocationAccountId();
    return true;
  }

  @override
  Future<String?> readPendingRevocationAccountId() async {
    return pendingRevocationAccountId;
  }

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async {
    _throwIf(_RevocationStorageFailure.saveMarker);
    pendingRevocationAccountId = accountId;
  }
}

enum _RevocationStorageFailure {
  saveMarker,
  clearCredential,
  clearAccount,
  clearMarker,
}

enum _AuthenticationFailureStage { currentUser, warehouses }

final class _MutableAuthRemoteDataSource implements AuthRemoteDataSource {
  _MutableAuthRemoteDataSource({
    required this.currentUserResult,
    required this.warehousesResult,
  });

  Result<AppUserModel> currentUserResult;
  Result<List<WarehouseModel>> warehousesResult;

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async => currentUserResult;

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async => warehousesResult;

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async => const FailureResult(UnknownFailure());

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => const FailureResult(UnknownFailure());
}

final class _ConcurrentSameTokenRemoteDataSource
    implements AuthRemoteDataSource {
  _ConcurrentSameTokenRemoteDataSource({required this.newerBootstrapFails});

  final bool newerBootstrapFails;
  final Completer<void> firstWarehouseStarted = Completer<void>();
  final Completer<void> releaseFirstWarehouse = Completer<void>();
  int _warehouseCalls = 0;

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async =>
      const FailureResult(UnknownFailure());

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async {
    _warehouseCalls += 1;
    if (_warehouseCalls == 1) {
      firstWarehouseStarted.complete();
      await releaseFirstWarehouse.future;
    } else if (newerBootstrapFails) {
      return const FailureResult(NetworkFailure(message: 'bootstrap failed'));
    }
    return const Success([
      WarehouseModel(id: 11, code: 'SH', name: 'Shanghai', isDefault: true),
    ]);
  }

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async => Success(
    LoginResponseModel(
      token: 'token',
      user: AppUserModel(
        id: username == 'alice' ? 7 : 8,
        username: username,
        realName: username,
        roleCode: 'user',
        roleName: 'User',
      ),
    ),
  );

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => const FailureResult(UnknownFailure());
}

final class _NoopOwnedFiles implements OfflineOwnedFileStore {
  const _NoopOwnedFiles();

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {}

  @override
  Future<void> clearAllFiles() async {}

  @override
  Future<void> clearDownloads(String accountId) async {}

  @override
  Future<void> clearStagedTransfers(String accountId) async {}

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async =>
      const OfflineFileOwnershipSnapshot();
}

final class _NoopOwnedScans implements OfflineOwnedScanStore {
  const _NoopOwnedScans();

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> clearForAccount(String accountId) async {}

  @override
  Future<int> countForAccount(String accountId) async => 0;
}

final class _NoopReviewInvalidator implements OfflineReviewInvalidator {
  const _NoopReviewInvalidator();

  @override
  Future<void> invalidate({
    required String accountId,
    int? warehouseId,
  }) async {}
}

final class _BlockingReviewInvalidator implements OfflineReviewInvalidator {
  final Completer<void> firstInvalidationStarted = Completer<void>();
  final Completer<void> releaseFirstInvalidation = Completer<void>();
  int invalidationCalls = 0;

  @override
  Future<void> invalidate({required String accountId, int? warehouseId}) async {
    invalidationCalls += 1;
    if (invalidationCalls != 1) return;
    firstInvalidationStarted.complete();
    await releaseFirstInvalidation.future;
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

final class _ConcurrentLoginAuthRepository
    implements AuthRepository, AuthTokenTransactionRepository {
  _ConcurrentLoginAuthRepository(this.storage);

  final _FakeSessionStorage storage;
  final Completer<void> aliceStarted = Completer<void>();
  final Completer<void> releaseAlice = Completer<void>();
  bool bobFails = false;

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    return loginWithTokenOwner(
      username: username,
      password: password,
      ownerId: 'raw-${username.hashCode}',
    );
  }

  @override
  Future<Result<AuthSession>> loginWithTokenOwner({
    required String username,
    required String password,
    required String ownerId,
  }) async {
    if (username == 'alice') {
      await storage.savePendingAccessTokenForOwner(
        token: 'token',
        ownerId: ownerId,
      );
      aliceStarted.complete();
      await releaseAlice.future;
      return const Success(_session);
    }
    if (bobFails) return const FailureResult(AuthenticationFailure());
    await storage.savePendingAccessTokenForOwner(
      token: 'token',
      ownerId: ownerId,
    );
    return const Success(_secondSameTokenSession);
  }

  @override
  Future<void> logout() => storage.clearAccessToken();

  @override
  Future<Result<AuthSession?>> restoreSession() async =>
      const Success<AuthSession?>(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);
}

final class _ThrowingCredentialRepository
    implements AuthRepository, AuthCredentialInvalidator {
  bool failExpiry = true;

  @override
  Future<void> expireCredentials() async {
    if (failExpiry) throw StateError('secure token clear failed');
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async => const Success(_session);

  @override
  Future<void> logout() async {}

  @override
  Future<Result<AuthSession?>> restoreSession() async =>
      const Success<AuthSession?>(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);
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
const _secondSameTokenSession = AuthSession(
  accessToken: 'token',
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
