import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';
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
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';
import 'package:rims_frontend/features/auth/domain/services/authenticated_request_lease.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

void main() {
  test(
    'real refresh chain uses marker fallback before credential and ownership cleanup',
    () async {
      final events = <String>[];
      final storage = _ChainStorage(_credential(), events: events)
        ..accountId = '7'
        ..failPrimaryMarker = true;
      final journal = _ChainJournal(events);
      final ownership = _ChainOwnership(events);
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      expect(await controller.startSession(_session), isTrue);
      storage.accountEpoch = controller.authEpoch;
      events.clear();
      ownership.intents.clear();
      final fixture = _buildFixture(
        storage: storage,
        journal: journal,
        ownership: ownership,
        controller: controller,
        events: events,
      );

      await expectLater(
        fixture.dio.get<dynamic>('/fallback'),
        throwsA(isA<DioException>()),
      );

      expect(fixture.remote.refreshCalls, 1);
      expect(controller.canAuthenticateRequests, isFalse);
      expect(controller.session, isNull);
      expect(storage.credential, isNull);
      expect(storage.accountId, isNull);
      expect(
        ownership.intents.single.reason,
        OfflineOwnershipReason.tokenExpiry,
      );
      expect(
        events,
        containsAllInOrder([
          'block',
          'journal-add',
          'primary-marker',
          'credential-clear',
          'account-cas-clear',
          'ownership',
        ]),
      );
    },
  );

  test('real refresh chain exposes dual marker failure as typed', () async {
    final events = <String>[];
    final storage = _ChainStorage(_credential(), events: events)
      ..accountId = '7'
      ..failPrimaryMarker = true;
    final journal = _ChainJournal(events)..failAdd = true;
    final ownership = _ChainOwnership(events);
    final controller = AuthSessionController(ownershipCoordinator: ownership);
    addTearDown(controller.dispose);
    expect(await controller.startSession(_session), isTrue);
    storage.accountEpoch = controller.authEpoch;
    events.clear();
    ownership.intents.clear();
    final fixture = _buildFixture(
      storage: storage,
      journal: journal,
      ownership: ownership,
      controller: controller,
      events: events,
    );

    final result = await fixture.coordinator.refreshAfterUnauthorized(
      failedCredential: _credential(),
      failedAuthEpoch: controller.authEpoch,
      origin: SessionRefreshOrigin.request,
    );

    expect(result, isA<FailureResult<DeviceCredential>>());
    expect(
      (result as FailureResult<DeviceCredential>).failure,
      isA<RevocationCleanupFailure>(),
    );
    expect(controller.canAuthenticateRequests, isFalse);
    expect(storage.credential, isNull);
    expect(ownership.intents.single.reason, OfflineOwnershipReason.tokenExpiry);
  });

  test('dual credential clear prevents a second interceptor refresh', () async {
    final events = <String>[];
    final storage = _ChainStorage(_credential(), events: events)
      ..accountId = '7'
      ..failConditionalClear = true
      ..failFallbackClear = true;
    final ownership = _ChainOwnership(events);
    final controller = AuthSessionController(ownershipCoordinator: ownership);
    addTearDown(controller.dispose);
    expect(await controller.startSession(_session), isTrue);
    storage.accountEpoch = controller.authEpoch;
    events.clear();
    ownership.intents.clear();
    final fixture = _buildFixture(
      storage: storage,
      journal: _ChainJournal(events),
      ownership: ownership,
      controller: controller,
      events: events,
    );

    await expectLater(
      fixture.dio.get<dynamic>('/first'),
      throwsA(isA<DioException>()),
    );
    await expectLater(
      fixture.dio.get<dynamic>('/second'),
      throwsA(isA<DioException>()),
    );

    expect(fixture.remote.refreshCalls, 1);
    expect(controller.canAuthenticateRequests, isFalse);
    expect(storage.credential, isNotNull);
    expect(fixture.adapter.fetchCount, 2);
  });

  test(
    'failed old refresh preserves a completed same-account new session',
    () async {
      final events = <String>[];
      final storage = _ChainStorage(_credential(), events: events)
        ..accountId = '7';
      final ownership = _ChainOwnership(events);
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      expect(await controller.startSession(_session), isTrue);
      storage.accountEpoch = controller.authEpoch;
      final store = MemoryOfflineStore();
      final releaseRefresh = Completer<void>();
      final fixture = _buildFixture(
        storage: storage,
        journal: _ChainJournal(events),
        ownership: ownership,
        controller: controller,
        events: events,
        store: store,
        refreshBlocker: releaseRefresh,
      );

      final oldRequest = fixture.dio.get<dynamic>('/old-refresh');
      await fixture.remote.refreshStarted.future;
      expect(await controller.startSession(_newSession), isTrue);
      storage
        ..credential = _credential(
          accessToken: 'access-new',
          refreshToken: 'refresh-new',
          sessionId: 'session-new',
        )
        ..accountId = '7';
      await store.writeCache(
        CacheRecord(
          key: const CacheKey(
            accountId: '7',
            namespace: 'auth.session',
            entityKey: 'projection',
          ),
          payload: const {'owner': 'new-session'},
          schemaVersion: 1,
          fetchedAt: DateTime.utc(2026, 7, 15),
          expiresAt: DateTime.utc(2026, 7, 16),
        ),
      );
      final ownershipCount = ownership.intents.length;
      releaseRefresh.complete();

      await expectLater(oldRequest, throwsA(isA<DioException>()));
      expect(controller.session?.accessToken, 'access-new');
      expect(controller.canAuthenticateRequests, isTrue);
      expect(storage.credential?.sessionId, 'session-new');
      expect(storage.accountId, '7');
      expect(
        (await store.readCache(
          const CacheKey(
            accountId: '7',
            namespace: 'auth.session',
            entityKey: 'projection',
          ),
          schemaVersion: 1,
        ))?.payload['owner'],
        'new-session',
      );
      expect(ownership.intents.length, ownershipCount);
      expect(storage.pendingAccountId, isNull);
    },
  );

  test(
    'old logout completion preserves a same-account new session projection',
    () async {
      final events = <String>[];
      final storage = _ChainStorage(_credential(), events: events)
        ..accountId = '7'
        ..accountEpoch = 1;
      final ownership = _ChainOwnership(events);
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      addTearDown(controller.dispose);
      expect(await controller.startSession(_session), isTrue);
      final store = MemoryOfflineStore();
      final releaseLogout = Completer<void>();
      final fixture = _buildFixture(
        storage: storage,
        journal: _ChainJournal(events),
        ownership: ownership,
        controller: controller,
        events: events,
        store: store,
        logoutBlocker: releaseLogout,
      );

      final oldLogout = controller.logout(authRepository: fixture.repository);
      await fixture.remote.logoutStarted.future;
      expect(controller.canAuthenticateRequests, isFalse);
      expect(await controller.startSession(_newSession), isTrue);
      storage
        ..credential = _credential(
          accessToken: 'access-new',
          refreshToken: 'refresh-new',
          sessionId: 'session-new',
        )
        ..accountId = '7'
        ..accountEpoch = controller.authEpoch;
      await store.writeCache(
        CacheRecord(
          key: const CacheKey(
            accountId: '7',
            namespace: 'auth.session',
            entityKey: 'projection',
          ),
          payload: {
            'owner': 'new-session',
            '_local_auth_epoch': controller.authEpoch,
          },
          schemaVersion: 1,
          fetchedAt: DateTime.utc(2026, 7, 15),
          expiresAt: DateTime.utc(2026, 7, 16),
        ),
      );
      releaseLogout.complete();
      await oldLogout;

      expect(fixture.remote.lastLogoutAccessToken, 'access-1');
      expect(controller.session, _newSession);
      expect(controller.canAuthenticateRequests, isTrue);
      expect(storage.credential?.sessionId, 'session-new');
      expect(storage.accountId, '7');
      expect(storage.accountEpoch, controller.authEpoch);
      expect(
        (await store.readCache(
          const CacheKey(
            accountId: '7',
            namespace: 'auth.session',
            entityKey: 'projection',
          ),
          schemaVersion: 1,
        ))?.payload['owner'],
        'new-session',
      );
    },
  );
}

_ChainFixture _buildFixture({
  required _ChainStorage storage,
  required _ChainJournal journal,
  required _ChainOwnership ownership,
  required AuthSessionController controller,
  required List<String> events,
  MemoryOfflineStore? store,
  Completer<void>? refreshBlocker,
  Completer<void>? logoutBlocker,
}) {
  final remote = _FailingRotatingRemote(
    refreshBlocker: refreshBlocker,
    logoutBlocker: logoutBlocker,
  );
  final rawRepository = AuthRepositoryImpl(
    remoteDataSource: remote,
    secureStorage: storage,
  );
  final cachedRepository = CachedAuthRepository(
    delegate: rawRepository,
    store: store ?? MemoryOfflineStore(),
    tokenStorage: storage,
    accountStorage: storage,
    revocationStorage: storage,
    revocationJournal: journal,
    ownershipCoordinator: ownership,
    authEpochReader: () => controller.authEpoch,
    onSessionRevoked: controller.invalidateRevokedSession,
    onSessionExpired: controller.invalidateExpiredSession,
  );
  final coordinator = SessionRefreshCoordinator(
    credentialStorage: storage,
    tokenStorage: storage,
    pendingRevocationStorage: storage,
    repository: rawRepository,
    blockAuthentication: (lease) {
      if (controller.authEpoch != lease.authEpoch ||
          !controller.canAuthenticateRequests ||
          controller.currentUser?.id.toString() != lease.credential.accountId) {
        return null;
      }
      events.add('block');
      controller.invalidateExpiredSession();
      return controller.authEpoch;
    },
    failureRecovery: cachedRepository,
  );
  final adapter = _AlwaysUnauthorizedAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  dio.interceptors.add(
    AuthInterceptor(
      authenticatedRequestLeaseReader: () async {
        if (!controller.canAuthenticateRequests) return null;
        final credential = await storage.readDeviceCredential();
        final token = await storage.readAccessToken();
        if (credential == null || token != credential.accessToken) return null;
        return AuthenticatedRequestLease(
          token: token!,
          credential: credential,
          authEpoch: controller.authEpoch,
        );
      },
      refreshCoordinator: coordinator,
      requestExecutor: dio.fetch,
    ),
  );
  return _ChainFixture(
    dio: dio,
    coordinator: coordinator,
    repository: cachedRepository,
    remote: remote,
    adapter: adapter,
  );
}

final class _ChainFixture {
  const _ChainFixture({
    required this.dio,
    required this.coordinator,
    required this.repository,
    required this.remote,
    required this.adapter,
  });

  final Dio dio;
  final SessionRefreshCoordinator coordinator;
  final CachedAuthRepository repository;
  final _FailingRotatingRemote remote;
  final _AlwaysUnauthorizedAdapter adapter;
}

final class _ChainStorage
    implements
        DeviceCredentialStorage,
        TokenStorage,
        AuthenticatedAccountStorage,
        ConditionalAuthenticatedAccountStorage,
        PendingRevocationStorage {
  _ChainStorage(this.credential, {required this.events});

  final List<String> events;
  DeviceCredential? credential;
  String? accountId;
  int? accountEpoch;
  String? pendingAccountId;
  bool failPrimaryMarker = false;
  bool failConditionalClear = false;
  bool failFallbackClear = false;

  @override
  Future<void> clearAccessToken() async {
    events.add('fallback-clear');
    if (failFallbackClear) throw StateError('fallback clear failed');
    credential = null;
  }

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async {
    events.add('credential-clear');
    if (failConditionalClear) throw StateError('conditional clear failed');
    final current = credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    credential = null;
    return true;
  }

  @override
  Future<String?> readAccessToken() async => credential?.accessToken;

  @override
  Future<DeviceCredential?> readDeviceCredential() async => credential;

  @override
  Future<void> saveAccessToken(String token) async =>
      throw UnsupportedError('device credentials only');

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) async => throw UnsupportedError('not used');

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async {
    final current = this.credential;
    if (current?.accountId != expectedAccountId ||
        current?.sessionId != expectedSessionId ||
        current?.generation != expectedGeneration) {
      return false;
    }
    this.credential = credential;
    return true;
  }

  @override
  Future<String?> readAuthenticatedAccountId() async => accountId;

  @override
  Future<void> saveAuthenticatedAccountId(String accountId) async {
    this.accountId = accountId;
  }

  @override
  Future<void> clearAuthenticatedAccountId() async {
    events.add('account-clear');
    accountId = null;
    accountEpoch = null;
  }

  @override
  Future<bool> clearAuthenticatedAccountIfMatches({
    required String accountId,
    required int authEpoch,
  }) async {
    events.add('account-cas-clear');
    if (this.accountId != accountId || accountEpoch != authEpoch) return false;
    this.accountId = null;
    accountEpoch = null;
    return true;
  }

  @override
  Future<String?> readPendingRevocationAccountId() async => pendingAccountId;

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async {
    events.add('primary-marker');
    if (failPrimaryMarker) throw StateError('primary marker failed');
    pendingAccountId = accountId;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    pendingAccountId = null;
  }
}

final class _ChainJournal implements PendingRevocationJournal {
  _ChainJournal(this.events);

  final List<String> events;
  final Set<String> accountIds = {};
  bool failAdd = false;

  @override
  Future<void> addAccountId(String accountId) async {
    events.add('journal-add');
    if (failAdd) throw StateError('journal failed');
    accountIds.add(accountId);
  }

  @override
  Future<Set<String>> readAccountIds() async => Set.unmodifiable(accountIds);

  @override
  Future<void> removeAccountId(String accountId) async {
    events.add('journal-remove');
    accountIds.remove(accountId);
  }
}

final class _ChainOwnership implements OfflineOwnershipCoordinator {
  _ChainOwnership(this.events);

  final List<String> events;
  final List<OfflineOwnershipIntent> intents = [];

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    events.add('ownership');
    intents.add(intent);
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
}

final class _FailingRotatingRemote
    implements AuthRemoteDataSource, RotatingAuthRemoteDataSource {
  _FailingRotatingRemote({this.refreshBlocker, this.logoutBlocker});

  final Completer<void>? refreshBlocker;
  final Completer<void>? logoutBlocker;
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> logoutStarted = Completer<void>();
  int refreshCalls = 0;
  String? lastLogoutAccessToken;

  @override
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async {
    refreshCalls += 1;
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    await refreshBlocker?.future;
    return const FailureResult(AuthenticationFailure());
  }

  @override
  Future<Result<void>> logout({required String accessToken}) async {
    lastLogoutAccessToken = accessToken;
    if (!logoutStarted.isCompleted) logoutStarted.complete();
    await logoutBlocker?.future;
    return const Success(null);
  }

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async => const FailureResult(UnknownFailure());

  @override
  Future<Result<AppUserModel>> loadCurrentUser({String? accessToken}) async =>
      const FailureResult(UnknownFailure());

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async => const FailureResult(UnknownFailure());

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => const FailureResult(UnknownFailure());
}

final class _AlwaysUnauthorizedAdapter implements HttpClientAdapter {
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount += 1;
    return ResponseBody.fromString('unauthorized', 401);
  }

  @override
  void close({bool force = false}) {}
}

DeviceCredential _credential({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  String sessionId = 'session-7',
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: '7',
  sessionId: sessionId,
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 5,
  generation: 1,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);

const _warehouse = Warehouse(
  id: 11,
  code: 'SH',
  name: 'Shanghai',
  isDefault: true,
);

const _session = AuthSession(
  accessToken: 'access-1',
  user: AppUser(
    id: 7,
    username: 'alice',
    realName: 'Alice',
    roleCode: 'user',
    roleName: 'User',
  ),
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);

const _newSession = AuthSession(
  accessToken: 'access-new',
  user: AppUser(
    id: 7,
    username: 'alice',
    realName: 'Alice',
    roleCode: 'user',
    roleName: 'User',
  ),
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);
