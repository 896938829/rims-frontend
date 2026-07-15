import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/core/storage/pending_revocation_journal.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/terminal_session_revocation.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/domain/services/authenticated_request_lease.dart';
import 'package:rims_frontend/features/auth/domain/services/auth_session_lifecycle_gate.dart';
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

void main() {
  test(
    'new login waits for logout ownership and remote revoke before committing',
    () async {
      final gate = AuthSessionLifecycleGate();
      final secureStorage = AppSecureStorage(
        storage: _MemoryFlutterSecureStorage(),
      );
      final ownership = _BlockingLogoutOwnership();
      final controller = AuthSessionController(
        ownershipCoordinator: ownership,
        lifecycleGate: gate,
      );
      addTearDown(controller.dispose);
      final remote = _LifecycleRemote();
      final rawRepository = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: secureStorage,
        authEpochReader: () => controller.authEpoch,
      );
      final repository = CachedAuthRepository(
        delegate: rawRepository,
        store: MemoryOfflineStore(),
        tokenStorage: secureStorage,
        accountStorage: secureStorage,
        revocationStorage: secureStorage,
        revocationJournal: MemoryPendingRevocationJournal(),
        ownershipCoordinator: ownership,
        authEpochReader: () => controller.authEpoch,
        onSessionRevoked: controller.invalidateRevokedSession,
        onSessionExpired: controller.invalidateExpiredSession,
      );

      final initialLogin = await controller.login(
        authRepository: repository,
        username: 'old-user',
        password: 'secret',
      );
      expect(
        initialLogin,
        isA<Success<void>>(),
        reason: switch (initialLogin) {
          FailureResult<void>(failure: final failure) => failure.message,
          _ => null,
        },
      );
      expect(
        (await secureStorage.readDeviceCredential())?.accessToken,
        'old-access',
      );
      ownership.blockLogout = true;

      final loggingOut = controller.logout(authRepository: repository);
      await ownership.logoutStarted.future;
      expect(controller.canAuthenticateRequests, isFalse);

      final loggingIn = controller.login(
        authRepository: repository,
        username: 'new-user',
        password: 'secret',
      );
      await Future<void>.delayed(Duration.zero);
      expect(remote.loginCalls, 1);

      ownership.releaseLogout.complete();
      await remote.logoutStarted.future;
      expect(remote.lastLogoutAccessToken, 'old-access');
      expect(remote.loginCalls, 1);

      remote.releaseLogout.complete();
      await loggingOut;
      expect(await loggingIn, isA<Success<void>>());

      final current = await secureStorage.readDeviceCredential();
      expect(current?.accessToken, 'new-access');
      expect(current?.sessionId, 'new-session');
      expect(controller.currentUser?.username, 'new-user');
      expect(remote.lastLogoutAccessToken, isNot('new-access'));
    },
  );

  test(
    'refresh commit finishes before a queued logout clears latest token',
    () async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.controller.dispose);
      fixture.remote.blockRefresh = true;

      final refreshing = fixture.coordinator.refreshAfterUnauthorized(
        failedCredential: fixture.credential,
        failedAuthEpoch: fixture.controller.authEpoch,
        origin: SessionRefreshOrigin.request,
      );
      await fixture.remote.refreshStarted.future;
      final loggingOut = fixture.controller.logout(
        authRepository: fixture.repository,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.remote.logoutStarted.isCompleted, isFalse);

      fixture.remote.releaseRefresh.complete();
      expect(await refreshing, isA<Success<DeviceCredential>>());
      await fixture.remote.logoutStarted.future;
      expect(fixture.remote.lastLogoutAccessToken, 'rotated-access');
      fixture.remote.releaseLogout.complete();
      await loggingOut;

      expect(await fixture.storage.readDeviceCredential(), isNull);
    },
  );

  test(
    'logout gate prevents a queued refresh remote call and commit',
    () async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.controller.dispose);
      fixture.ownership.blockLogout = true;

      final loggingOut = fixture.controller.logout(
        authRepository: fixture.repository,
      );
      await fixture.ownership.logoutStarted.future;
      final refreshing = fixture.coordinator.refreshAfterUnauthorized(
        failedCredential: fixture.credential,
        failedAuthEpoch: fixture.controller.authEpoch,
        origin: SessionRefreshOrigin.request,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.remote.refreshCalls, 0);

      fixture.ownership.releaseLogout.complete();
      await fixture.remote.logoutStarted.future;
      fixture.remote.releaseLogout.complete();
      await loggingOut;

      expect(await refreshing, isA<FailureResult<DeviceCredential>>());
      expect(fixture.remote.refreshCalls, 0);
      expect(await fixture.storage.readDeviceCredential(), isNull);
    },
  );

  test(
    'terminal revocation holds refresh login and logout in the shared gate',
    () async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.controller.dispose);
      final repository = _CountingAuthRepository(fixture.repository);
      final remoteStarted = Completer<void>();
      final releaseRemote = Completer<void>();

      final revoking = fixture.controller.runSessionRevocation(
        authRepository: repository,
        remoteRevocation: () async {
          remoteStarted.complete();
          await releaseRemote.future;
          return const Success(null);
        },
      );
      await remoteStarted.future;

      final refreshing = fixture.controller.refreshSession(repository);
      final loggingIn = fixture.controller.login(
        authRepository: repository,
        username: 'new-user',
        password: 'secret',
      );
      final loggingOut = fixture.controller.logout(authRepository: repository);
      await Future<void>.delayed(Duration.zero);

      expect(repository.restoreCalls, 0);
      expect(repository.loginCalls, 0);
      expect(repository.logoutCalls, 0);
      expect(repository.expireCalls, 0);
      expect(fixture.controller.isAuthenticated, isTrue);

      releaseRemote.complete();
      expect(
        (await revoking).status,
        TerminalSessionRevocationStatus.completed,
      );
      expect(repository.expireCalls, 1);
      expect(fixture.controller.isAuthenticated, isFalse);

      await refreshing;
      await loggingIn;
      await fixture.remote.logoutStarted.future;
      fixture.remote.releaseLogout.complete();
      await loggingOut;
      expect(repository.restoreCalls, 1);
      expect(repository.loginCalls, 1);
      expect(repository.logoutCalls, 1);
    },
  );

  test(
    'remote revocation failure skips local cleanup and logout state',
    () async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.controller.dispose);
      final repository = _CountingAuthRepository(fixture.repository);

      final result = await fixture.controller.runSessionRevocation(
        authRepository: repository,
        remoteRevocation: () async => const FailureResult(
          NetworkFailure(message: 'remote revoke failed'),
        ),
      );

      expect(result.status, TerminalSessionRevocationStatus.remoteRejected);
      expect(repository.expireCalls, 0);
      expect(fixture.ownership.revocationCalls, 0);
      expect(fixture.controller.isAuthenticated, isTrue);
    },
  );

  test(
    'credential cleanup failure remains terminal after remote success',
    () async {
      final fixture = await _LifecycleFixture.create();
      addTearDown(fixture.controller.dispose);
      final repository = _CountingAuthRepository(
        fixture.repository,
        failCredentialCleanup: true,
      );
      var remoteRevocationCalls = 0;

      final result = await fixture.controller.runSessionRevocation(
        authRepository: repository,
        remoteRevocation: () async {
          remoteRevocationCalls += 1;
          return const Success(null);
        },
      );

      expect(
        result.status,
        TerminalSessionRevocationStatus.terminalWithCleanupDebt,
      );
      expect(repository.expireCalls, 1);
      expect(fixture.ownership.revocationCalls, 1);
      expect(fixture.controller.isAuthenticated, isFalse);
      expect(fixture.controller.currentUser, isNull);
      expect(fixture.controller.canAuthenticateRequests, isFalse);
      expect(remoteRevocationCalls, 1);
      expect(fixture.remote.logoutCalls, 0);
      expect(await fixture.journal.readLeases(), hasLength(1));

      final restartedOwnership = _BlockingLogoutOwnership();
      final restartedController = AuthSessionController(
        ownershipCoordinator: restartedOwnership,
      );
      addTearDown(restartedController.dispose);
      final restartedRaw = AuthRepositoryImpl(
        remoteDataSource: fixture.remote,
        secureStorage: fixture.storage,
        authEpochReader: () => restartedController.authEpoch,
      );
      final restartedRepository = CachedAuthRepository(
        delegate: restartedRaw,
        store: fixture.store,
        tokenStorage: fixture.storage,
        accountStorage: fixture.storage,
        revocationStorage: fixture.storage,
        revocationJournal: fixture.journal,
        ownershipCoordinator: restartedOwnership,
        authEpochReader: () => restartedController.authEpoch,
        onSessionRevoked: restartedController.invalidateRevokedSession,
      );

      await restartedController.restoreSession(restartedRepository);

      expect(restartedController.isAuthenticated, isFalse);
      expect(await fixture.storage.readDeviceCredential(), isNull);
      expect(
        await fixture.journal.readLeases(),
        isEmpty,
        reason:
            'restore=${restartedController.restoreFailure} '
            'ownership=${restartedController.ownershipFailure} '
            'epoch=${restartedController.authEpoch}',
      );
      expect(fixture.remote.loadCurrentUserCalls, 0);
      expect(fixture.remote.logoutCalls, 0);
    },
  );
}

final class _LifecycleFixture {
  const _LifecycleFixture({
    required this.storage,
    required this.controller,
    required this.remote,
    required this.repository,
    required this.coordinator,
    required this.ownership,
    required this.credential,
    required this.journal,
    required this.store,
  });

  static Future<_LifecycleFixture> create() async {
    final gate = AuthSessionLifecycleGate();
    final storage = AppSecureStorage(storage: _MemoryFlutterSecureStorage());
    final ownership = _BlockingLogoutOwnership();
    final controller = AuthSessionController(
      ownershipCoordinator: ownership,
      lifecycleGate: gate,
    );
    final remote = _LifecycleRemote();
    final journal = MemoryPendingRevocationJournal();
    final store = MemoryOfflineStore();
    final raw = AuthRepositoryImpl(
      remoteDataSource: remote,
      secureStorage: storage,
      authEpochReader: () => controller.authEpoch,
    );
    final repository = CachedAuthRepository(
      delegate: raw,
      store: store,
      tokenStorage: storage,
      accountStorage: storage,
      revocationStorage: storage,
      revocationJournal: journal,
      ownershipCoordinator: ownership,
      authEpochReader: () => controller.authEpoch,
      onSessionRevoked: controller.invalidateRevokedSession,
      onSessionExpired: controller.invalidateExpiredSession,
    );
    expect(
      await controller.login(
        authRepository: repository,
        username: 'old-user',
        password: 'secret',
      ),
      isA<Success<void>>(),
    );
    final credential = (await storage.readDeviceCredential())!;
    Future<AuthenticatedRequestLease?> readLease() async {
      if (!controller.canAuthenticateRequests) return null;
      final current = await storage.readDeviceCredential();
      if (current == null || current.accountId != '7') return null;
      return AuthenticatedRequestLease(
        token: current.accessToken,
        credential: current,
        authEpoch: controller.authEpoch,
      );
    }

    return _LifecycleFixture(
      storage: storage,
      controller: controller,
      remote: remote,
      repository: repository,
      coordinator: SessionRefreshCoordinator(
        credentialStorage: storage,
        tokenStorage: storage,
        pendingRevocationStorage: storage,
        repository: raw,
        authenticatedRequestLeaseReader: readLease,
        lifecycleGate: gate,
      ),
      ownership: ownership,
      credential: credential,
      journal: journal,
      store: store,
    );
  }

  final AppSecureStorage storage;
  final AuthSessionController controller;
  final _LifecycleRemote remote;
  final CachedAuthRepository repository;
  final SessionRefreshCoordinator coordinator;
  final _BlockingLogoutOwnership ownership;
  final DeviceCredential credential;
  final MemoryPendingRevocationJournal journal;
  final MemoryOfflineStore store;
}

final class _LifecycleRemote
    implements AuthRemoteDataSource, RotatingAuthRemoteDataSource {
  int loginCalls = 0;
  final Completer<void> logoutStarted = Completer<void>();
  final Completer<void> releaseLogout = Completer<void>();
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> releaseRefresh = Completer<void>();
  String? lastLogoutAccessToken;
  bool blockRefresh = false;
  int refreshCalls = 0;
  int logoutCalls = 0;
  int loadCurrentUserCalls = 0;

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async {
    loginCalls += 1;
    final isNew = username == 'new-user';
    return Success(
      _response(
        username: username,
        accessToken: isNew ? 'new-access' : 'old-access',
        refreshToken: isNew ? 'new-refresh' : 'old-refresh',
        sessionId: isNew ? 'new-session' : 'old-session',
      ),
    );
  }

  @override
  Future<Result<void>> logout({required String accessToken}) async {
    logoutCalls += 1;
    lastLogoutAccessToken = accessToken;
    if (!logoutStarted.isCompleted) logoutStarted.complete();
    await releaseLogout.future;
    return const Success(null);
  }

  @override
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async {
    refreshCalls += 1;
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    if (blockRefresh) await releaseRefresh.future;
    return Success(
      _response(
        username: 'old-user',
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
        sessionId: 'old-session',
      ),
    );
  }

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async {
    loadCurrentUserCalls += 1;
    throw UnsupportedError('not used');
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async => const Success([]);

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => throw UnsupportedError('not used');

  LoginResponseModel _response({
    required String username,
    required String accessToken,
    required String refreshToken,
    required String sessionId,
  }) => LoginResponseModel(
    token: accessToken,
    refreshToken: refreshToken,
    accessExpiresAt: DateTime.utc(2030, 7, 15, 3),
    refreshExpiresAt: DateTime.utc(2030, 8, 15, 3),
    tokenVersion: 5,
    session: DeviceSessionModel(
      id: sessionId,
      deviceLabel: 'Test device',
      platform: 'windows',
      userAgentFamily: 'flutter',
      createdAt: DateTime.utc(2026, 7, 15),
      lastUsedAt: DateTime.utc(2026, 7, 15),
      expiresAt: DateTime.utc(2030, 8, 15, 3),
      current: true,
    ),
    user: AppUserModel(
      id: 7,
      username: username,
      realName: username,
      roleCode: 'operator',
      roleName: 'Operator',
    ),
  );
}

final class _BlockingLogoutOwnership
    implements OfflineOwnershipCoordinator, OfflineReauthenticationCoordinator {
  bool blockLogout = false;
  int revocationCalls = 0;
  final Completer<void> logoutStarted = Completer<void>();
  final Completer<void> releaseLogout = Completer<void>();

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    if (intent.reason == OfflineOwnershipReason.revocation) {
      revocationCalls += 1;
    }
    if (blockLogout && intent.reason == OfflineOwnershipReason.logout) {
      if (!logoutStarted.isCompleted) logoutStarted.complete();
      await releaseLogout.future;
    }
    return OfflineOwnershipReport(
      reason: intent.reason,
      accountId: intent.accountId,
      executedCounts: const OfflineOwnershipCounts(),
      failures: const [],
    );
  }

  @override
  bool canAccessOfflineData(String accountId) => true;

  @override
  bool canSync(String accountId) => true;

  @override
  Future<OfflineReauthenticationLease> prepareReauthentication({
    required String accountId,
  }) async => _ImmediateReauthenticationLease(accountId);
}

final class _CountingAuthRepository
    implements
        AuthRepository,
        AuthCredentialInvalidator,
        OwnerBoundCredentialQuarantine,
        SessionFailureRecovery {
  _CountingAuthRepository(this.delegate, {this.failCredentialCleanup = false});

  final AuthRepository delegate;
  final bool failCredentialCleanup;
  int restoreCalls = 0;
  int loginCalls = 0;
  int logoutCalls = 0;
  int expireCalls = 0;

  @override
  Future<Result<AuthSession?>> restoreSession() {
    restoreCalls += 1;
    return delegate.restoreSession();
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) {
    loginCalls += 1;
    return delegate.login(username: username, password: password);
  }

  @override
  Future<void> logout() {
    logoutCalls += 1;
    return delegate.logout();
  }

  @override
  Future<void> expireCredentials() async {
    expireCalls += 1;
    if (failCredentialCleanup) {
      throw StateError('credential cleanup failed');
    }
    final invalidator = delegate as AuthCredentialInvalidator;
    await invalidator.expireCredentials();
  }

  @override
  Future<DeviceCredential?> captureCredentialForQuarantine() {
    final quarantine = delegate as OwnerBoundCredentialQuarantine;
    return quarantine.captureCredentialForQuarantine();
  }

  @override
  Future<bool> quarantineCredential(DeviceCredential expected) async {
    expireCalls += 1;
    if (failCredentialCleanup) {
      throw StateError('credential cleanup failed');
    }
    final quarantine = delegate as OwnerBoundCredentialQuarantine;
    return quarantine.quarantineCredential(expected);
  }

  @override
  Future<Failure?> retainPendingRevocation({
    required SessionRevocationLease markerLease,
    required AuthenticatedSessionCleanupLease cleanupLease,
  }) {
    final recovery = delegate as SessionFailureRecovery;
    return recovery.retainPendingRevocation(
      markerLease: markerLease,
      cleanupLease: cleanupLease,
    );
  }

  @override
  Future<Failure?> completeOwnershipCleanup({
    required SessionRevocationLease markerLease,
    required AuthenticatedSessionCleanupLease cleanupLease,
    required bool credentialQuarantined,
    bool ownershipCompleted = false,
  }) {
    final recovery = delegate as SessionFailureRecovery;
    return recovery.completeOwnershipCleanup(
      markerLease: markerLease,
      cleanupLease: cleanupLease,
      credentialQuarantined: credentialQuarantined,
      ownershipCompleted: ownershipCompleted,
    );
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

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) =>
      delegate.switchCurrentWarehouse(warehouse);
}

final class _ImmediateReauthenticationLease
    implements OfflineReauthenticationLease {
  _ImmediateReauthenticationLease(String accountId)
    : report = OfflineOwnershipReport(
        reason: OfflineOwnershipReason.reauthenticated,
        accountId: accountId,
        executedCounts: const OfflineOwnershipCounts(),
        failures: const [],
      );

  @override
  final OfflineOwnershipReport report;

  @override
  Future<Result<OfflineOwnershipReport>> finalize() async => Success(report);

  @override
  Result<void> rollback() => const Success(null);

  @override
  Future<T> runScopedWrite<T>(Future<T> Function() operation) => operation();
}

final class _MemoryFlutterSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
