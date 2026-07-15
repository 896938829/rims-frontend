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
          'account-clear',
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
}

_ChainFixture _buildFixture({
  required _ChainStorage storage,
  required _ChainJournal journal,
  required _ChainOwnership ownership,
  required AuthSessionController controller,
  required List<String> events,
}) {
  final remote = _FailingRotatingRemote();
  final rawRepository = AuthRepositoryImpl(
    remoteDataSource: remote,
    secureStorage: storage,
  );
  final cachedRepository = CachedAuthRepository(
    delegate: rawRepository,
    store: MemoryOfflineStore(),
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
    blockAuthentication: (accountId) {
      if (controller.currentUser?.id.toString() == accountId) {
        events.add('block');
        controller.invalidateExpiredSession();
      }
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
    remote: remote,
    adapter: adapter,
  );
}

final class _ChainFixture {
  const _ChainFixture({
    required this.dio,
    required this.coordinator,
    required this.remote,
    required this.adapter,
  });

  final Dio dio;
  final SessionRefreshCoordinator coordinator;
  final _FailingRotatingRemote remote;
  final _AlwaysUnauthorizedAdapter adapter;
}

final class _ChainStorage
    implements
        DeviceCredentialStorage,
        TokenStorage,
        AuthenticatedAccountStorage,
        PendingRevocationStorage {
  _ChainStorage(this.credential, {required this.events});

  final List<String> events;
  DeviceCredential? credential;
  String? accountId;
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
  int refreshCalls = 0;

  @override
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async {
    refreshCalls += 1;
    return const FailureResult(AuthenticationFailure());
  }

  @override
  Future<Result<void>> logout() async => const Success(null);

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

DeviceCredential _credential() => DeviceCredential(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accountId: '7',
  sessionId: 'session-7',
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
