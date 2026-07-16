import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/login_view_model.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

import '../../support/unsupported_device_sessions.dart';

void main() {
  test(
    'plain TokenStorage cancelled login clears credential before restart restore',
    () async {
      final storage = _PlainTokenStorage();
      final remote = _CleanupRemote(rotating: false);
      final ownership = _BlockingReauthenticationOwnership();
      final controller = AuthSessionController(ownershipCoordinator: ownership);
      final repository = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: storage,
      );
      expect(repository, isNot(isA<TransactionalAuthRepository>()));
      final viewModel = _loginViewModel(repository, controller);

      final login = viewModel.login();
      await ownership.started.future;
      expect(await storage.readAccessToken(), isNull);
      viewModel.dispose();
      ownership.release.complete();

      expect(await login, isFalse);
      expect(await storage.readAccessToken(), isNull);
      expect(controller.session, isNull);
      expect(remote.logoutCalls, 0);

      final restartedRemote = _CleanupRemote(rotating: false);
      final restartedRepository = AuthRepositoryImpl(
        remoteDataSource: restartedRemote,
        secureStorage: storage,
      );
      final restarted = AuthSessionController();
      await restarted.restoreSession(restartedRepository);
      expect(restarted.session, isNull);
      expect(restartedRemote.loadCurrentUserCalls, 0);
      expect(restartedRemote.logoutCalls, 0);
    },
  );

  test(
    'AppSecureStorage cancelled login clears committed owner before restore',
    () async {
      final raw = _FaultInjectingSecureStorage()..blockCommittedWrite = true;
      final storage = AppSecureStorage(storage: raw);
      final remote = _CleanupRemote(rotating: true);
      final controller = AuthSessionController();
      final repository = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: storage,
        tokenOwnerFactory: () => 'cancelled-owner',
      );
      final viewModel = _loginViewModel(repository, controller);

      final login = viewModel.login();
      await raw.committedWriteStarted.future;
      viewModel.dispose();
      raw.releaseCommittedWrite.complete();

      expect(await login, isFalse);
      expect(await storage.readDeviceCredential(), isNull);
      expect(controller.session, isNull);
      expect(remote.logoutCalls, 0);

      final restartedRemote = _CleanupRemote(rotating: true);
      final restartedRepository = AuthRepositoryImpl(
        remoteDataSource: restartedRemote,
        secureStorage: AppSecureStorage(storage: raw),
      );
      final restarted = AuthSessionController();
      await restarted.restoreSession(restartedRepository);
      expect(restarted.session, isNull);
      expect(restartedRemote.loadCurrentUserCalls, 0);
      expect(restartedRemote.logoutCalls, 0);
    },
  );

  test(
    'abort delete failure leaves unreadable debt and surfaces cleanup failure',
    () async {
      final raw = _FaultInjectingSecureStorage()
        ..blockCommittedWrite = true
        ..failDeviceCredentialDeletes = true;
      final storage = AppSecureStorage(storage: raw);
      final remote = _CleanupRemote(rotating: true);
      final controller = AuthSessionController();
      final repository = AuthRepositoryImpl(
        remoteDataSource: remote,
        secureStorage: storage,
        tokenOwnerFactory: () => 'debt-owner',
      );
      final viewModel = _loginViewModel(repository, controller);

      final login = viewModel.login();
      await raw.committedWriteStarted.future;
      viewModel.dispose();
      raw.releaseCommittedWrite.complete();

      expect(await login, isFalse);
      expect(controller.session, isNull);
      expect(controller.ownershipFailure, isA<RevocationCleanupFailure>());
      expect(await storage.readDeviceCredential(), isNull);
      expect(remote.logoutCalls, 0);

      final restartedRemote = _CleanupRemote(rotating: true);
      final restartedRepository = AuthRepositoryImpl(
        remoteDataSource: restartedRemote,
        secureStorage: AppSecureStorage(storage: raw),
      );
      final restored = await restartedRepository.restoreSession();
      expect(restored, isA<FailureResult<Object?>>());
      expect(restartedRemote.loadCurrentUserCalls, 0);
      expect(restartedRemote.logoutCalls, 0);
    },
  );

  test('old owner abort cannot clear a newer owner credential', () async {
    final raw = _FaultInjectingSecureStorage();
    final storage = AppSecureStorage(storage: raw);
    final remote = _CleanupRemote(rotating: true);
    final owners = ['old-owner', 'new-owner'].iterator;
    final repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      secureStorage: storage,
      tokenOwnerFactory: () {
        owners.moveNext();
        return owners.current;
      },
    );

    final oldPrepared = await repository.prepareLogin(
      username: 'old-user',
      password: 'secret',
    );
    final oldTransaction = _transaction(oldPrepared);
    expect(await oldTransaction.commit(), isA<Success<void>>());

    remote.nextAccessToken = 'access-2';
    remote.nextRefreshToken = 'refresh-2';
    remote.nextSessionId = 'session-2';
    final newPrepared = await repository.prepareLogin(
      username: 'new-user',
      password: 'secret',
    );
    final newTransaction = _transaction(newPrepared);
    expect(await newTransaction.commit(), isA<Success<void>>());
    expect(await oldTransaction.abort(), isA<Success<void>>());

    final credential = await storage.readDeviceCredential();
    expect(credential?.accessToken, 'access-2');
    expect(credential?.sessionId, 'session-2');
    expect(remote.logoutCalls, 0);
  });

  test('plain storage old cleanup preserves a newer login owner', () async {
    final storage = _PlainTokenStorage();
    final oldRemote = _CleanupRemote(rotating: false);
    final oldOwnership = _BlockingReauthenticationOwnership();
    final oldController = AuthSessionController(
      ownershipCoordinator: oldOwnership,
    );
    final oldViewModel = _loginViewModel(
      AuthRepositoryImpl(
        remoteDataSource: oldRemote,
        secureStorage: storage,
        tokenOwnerFactory: () => 'plain-old-owner',
      ),
      oldController,
    );

    final oldLogin = oldViewModel.login();
    await oldOwnership.started.future;
    expect(await storage.readAccessToken(), isNull);

    final newRemote = _CleanupRemote(rotating: false)
      ..nextAccessToken = 'access-2';
    final newController = AuthSessionController();
    final newViewModel = _loginViewModel(
      AuthRepositoryImpl(
        remoteDataSource: newRemote,
        secureStorage: storage,
        tokenOwnerFactory: () => 'plain-new-owner',
      ),
      newController,
    );
    expect(await newViewModel.login(), isTrue);
    expect(await storage.readAccessToken(), 'access-2');

    oldViewModel.dispose();
    oldOwnership.release.complete();
    expect(await oldLogin, isFalse);
    expect(await storage.readAccessToken(), 'access-2');
    expect(newController.session?.accessToken, 'access-2');
    expect(oldRemote.logoutCalls, 0);
    expect(newRemote.logoutCalls, 0);
  });
}

LoginViewModel _loginViewModel(
  AuthRepository repository,
  AuthSessionController controller,
) => LoginViewModel(authRepository: repository, sessionController: controller)
  ..updateUsername('alice')
  ..updatePassword('one-time-secret');

AuthSessionTransaction _transaction(Result<AuthSessionTransaction> prepared) =>
    prepared.when(
      success: (transaction) => transaction,
      failure: (failure) => throw TestFailure(failure.message),
    );

final class _PlainTokenStorage implements TokenStorage {
  String? token;

  @override
  Future<void> clearAccessToken() async => token = null;

  @override
  Future<String?> readAccessToken() async => token;

  @override
  Future<void> saveAccessToken(String token) async => this.token = token;
}

final class _BlockingReauthenticationOwnership
    implements OfflineOwnershipCoordinator {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    if (intent.reason == OfflineOwnershipReason.reauthenticated) {
      started.complete();
      await release.future;
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
}

final class _CleanupRemote
    with UnsupportedDeviceSessions
    implements AuthRemoteDataSource, RotatingAuthRemoteDataSource {
  _CleanupRemote({required this.rotating});

  final bool rotating;
  String nextAccessToken = 'access-1';
  String nextRefreshToken = 'refresh-1';
  String nextSessionId = 'session-1';
  int loadCurrentUserCalls = 0;
  int logoutCalls = 0;

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async => Success(
    LoginResponseModel(
      token: nextAccessToken,
      accessToken: nextAccessToken,
      refreshToken: rotating ? nextRefreshToken : null,
      accessExpiresAt: rotating ? DateTime.utc(2026, 7, 16, 2) : null,
      refreshExpiresAt: rotating ? DateTime.utc(2026, 7, 17, 2) : null,
      tokenVersion: rotating ? 1 : null,
      session: rotating
          ? DeviceSessionModel(
              id: nextSessionId,
              deviceLabel: 'Browser',
              platform: 'web',
              userAgentFamily: 'chrome',
              createdAt: DateTime.utc(2026, 7, 16),
              lastUsedAt: DateTime.utc(2026, 7, 16),
              expiresAt: DateTime.utc(2026, 7, 17),
              current: true,
            )
          : null,
      user: AppUserModel(
        id: nextAccessToken == 'access-1' ? 7 : 8,
        username: username,
        realName: username,
        roleCode: 'user',
        roleName: 'User',
      ),
    ),
  );

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async {
    loadCurrentUserCalls += 1;
    return const Success(
      AppUserModel(
        id: 7,
        username: 'alice',
        realName: 'Alice',
        roleCode: 'user',
        roleName: 'User',
      ),
    );
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async => const Success([
    WarehouseModel(id: 1, code: 'WH001', name: 'Warehouse', isDefault: true),
  ]);

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => const Success(null);

  @override
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async => const FailureResult(UnknownFailure());

  @override
  Future<Result<void>> logout({required String accessToken}) async {
    logoutCalls += 1;
    return const Success(null);
  }
}

final class _FaultInjectingSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};
  bool blockCommittedWrite = false;
  bool failDeviceCredentialDeletes = false;
  final Completer<void> committedWriteStarted = Completer<void>();
  final Completer<void> releaseCommittedWrite = Completer<void>();
  bool _blockedCommittedWrite = false;

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
    if (key == AppSecureStorage.kDeviceCredentialKey &&
        failDeviceCredentialDeletes) {
      throw StateError('injected device credential delete failure');
    }
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
      return;
    }
    values[key] = value;
    if (blockCommittedWrite &&
        !_blockedCommittedWrite &&
        key == AppSecureStorage.kDeviceCredentialKey &&
        value.contains('"state":"committed"')) {
      _blockedCommittedWrite = true;
      committedWriteStarted.complete();
      await releaseCommittedWrite.future;
    }
  }
}
