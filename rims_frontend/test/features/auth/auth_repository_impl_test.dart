import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/domain/services/authenticated_request_lease.dart';
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';

void main() {
  group('AuthRepositoryImpl', () {
    test('rotating login commits one owner-bound device credential', () async {
      final storage = _FakeDeviceCredentialStorage();
      final remoteDataSource = _FakeAuthRemoteDataSource(
        loginResult: Success(_rotatingLoginModel()),
        warehousesResult: const Success([]),
      );
      final repository = AuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: storage,
        tokenOwnerFactory: () => 'login-owner',
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result.isSuccess, isTrue);
      expect(storage.credential?.accessToken, 'access-1');
      expect(storage.credential?.refreshToken, 'refresh-1');
      expect(storage.credential?.accountId, '7');
      expect(storage.credential?.sessionId, 'session-7');
      expect(storage.credential?.generation, 1);
      expect(storage.tokenCommitted, isTrue);
    });

    test(
      'rotation candidate preserves identity and increments generation',
      () async {
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: Success(
            _rotatingLoginModel(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              tokenVersion: 6,
            ),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: _FakeDeviceCredentialStorage(),
        );

        final result = await (repository as SessionCredentialRepository)
            .refreshCredential(_deviceCredential());

        final next = result.when(
          success: (value) => value,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(remoteDataSource.lastRefreshToken, 'refresh-1');
        expect(next.accessToken, 'access-2');
        expect(next.refreshToken, 'refresh-2');
        expect(next.accountId, '7');
        expect(next.sessionId, 'session-7');
        expect(next.generation, 2);
        expect(next.biometricPolicy, BiometricCredentialPolicy.requireUnlock);
      },
    );

    test(
      'failed remote logout quarantines the rotating credential locally',
      () async {
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true;
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: const FailureResult(AuthenticationFailure()),
          logoutResult: const FailureResult(NetworkFailure()),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        await repository.logout();

        expect(storage.credential, isNull);
        expect(storage.readAccessToken(), completion(isNull));
        expect(storage.pendingAccountId, '7');
      },
    );

    test(
      'failed remote logout exposes marker failure after quarantine',
      () async {
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true
          ..pendingMarkerError = StateError('marker unavailable');
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeRotatingAuthRemoteDataSource(
            refreshResult: const FailureResult(AuthenticationFailure()),
            logoutResult: const FailureResult(NetworkFailure()),
          ),
          secureStorage: storage,
        );

        await expectLater(
          repository.logout(),
          throwsA(isA<RevocationCleanupFailure>()),
        );

        expect(storage.credential, isNull);
        expect(await storage.readAccessToken(), isNull);
        expect(storage.pendingAccountId, isNull);
      },
    );

    test(
      'real repository logout cannot be undone by an in-flight refresh',
      () async {
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true;
        final releaseRefresh = Completer<void>();
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: Success(
            _rotatingLoginModel(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              tokenVersion: 6,
            ),
          ),
          refreshBlocker: releaseRefresh,
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );
        final coordinator = SessionRefreshCoordinator(
          credentialStorage: storage,
          tokenStorage: storage,
          pendingRevocationStorage: storage,
          repository: repository,
        );

        final refreshing = coordinator.refreshAfterUnauthorized(
          failedCredential: _deviceCredential(),
          origin: SessionRefreshOrigin.request,
        );
        await remoteDataSource.refreshStarted.future;
        await repository.logout();
        releaseRefresh.complete();

        expect(await refreshing, isA<FailureResult<DeviceCredential>>());
        expect(storage.credential, isNull);
        expect(await storage.readAccessToken(), isNull);
        expect(remoteDataSource.logoutCalls, 1);
      },
    );

    test(
      'logout gate fences a remote refresh before its credential commit',
      () async {
        var canAuthenticate = true;
        var authEpoch = 4;
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true;
        final releaseRefresh = Completer<void>();
        final releaseLogout = Completer<void>();
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: Success(
            _rotatingLoginModel(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              tokenVersion: 6,
            ),
          ),
          refreshBlocker: releaseRefresh,
          logoutBlocker: releaseLogout,
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
          authEpochReader: () => authEpoch,
        );
        Future<AuthenticatedRequestLease?> readLease() async {
          final credential = await storage.readDeviceCredential();
          if (!canAuthenticate || credential == null) return null;
          return AuthenticatedRequestLease(
            token: credential.accessToken,
            credential: credential,
            authEpoch: authEpoch,
          );
        }

        final coordinator = SessionRefreshCoordinator(
          credentialStorage: storage,
          tokenStorage: storage,
          pendingRevocationStorage: storage,
          repository: repository,
          authenticatedRequestLeaseReader: readLease,
        );
        final refreshing = coordinator.refreshAfterUnauthorized(
          failedCredential: _deviceCredential(),
          failedAuthEpoch: authEpoch,
          origin: SessionRefreshOrigin.request,
        );
        await remoteDataSource.refreshStarted.future;

        canAuthenticate = false;
        final loggingOut = repository.logout();
        await remoteDataSource.logoutStarted.future;
        releaseRefresh.complete();
        expect(await refreshing, isA<FailureResult<DeviceCredential>>());
        releaseLogout.complete();
        await loggingOut;

        expect(storage.credential, isNull);
        expect(await storage.readAccessToken(), isNull);
        expect(authEpoch, 4);
      },
    );

    test(
      'logout clears a same-session higher generation when its epoch is unchanged',
      () async {
        var authEpoch = 4;
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true
          ..credentialBeforeNextClear = _deviceCredential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          );
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeRotatingAuthRemoteDataSource(
            refreshResult: const FailureResult(AuthenticationFailure()),
          ),
          secureStorage: storage,
          authEpochReader: () => authEpoch,
        );

        await repository.logout();

        expect(storage.credential, isNull);
        expect(await storage.readAccessToken(), isNull);
        expect(authEpoch, 4);
      },
    );

    test(
      'logout started after refresh commit clears the latest generation',
      () async {
        var canAuthenticate = true;
        const authEpoch = 4;
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true;
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: Success(
            _rotatingLoginModel(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              tokenVersion: 6,
            ),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
          authEpochReader: () => authEpoch,
        );
        final coordinator = SessionRefreshCoordinator(
          credentialStorage: storage,
          tokenStorage: storage,
          pendingRevocationStorage: storage,
          repository: repository,
          authenticatedRequestLeaseReader: () async {
            final credential = await storage.readDeviceCredential();
            if (!canAuthenticate || credential == null) return null;
            return AuthenticatedRequestLease(
              token: credential.accessToken,
              credential: credential,
              authEpoch: authEpoch,
            );
          },
        );

        final refreshed = await coordinator.refreshAfterUnauthorized(
          failedCredential: _deviceCredential(),
          failedAuthEpoch: authEpoch,
          origin: SessionRefreshOrigin.request,
        );
        expect(refreshed, isA<Success<DeviceCredential>>());
        expect(storage.credential?.generation, 2);

        canAuthenticate = false;
        await repository.logout();

        expect(storage.credential, isNull);
        expect(await storage.readAccessToken(), isNull);
        expect(remoteDataSource.lastLogoutAccessToken, 'access-2');
      },
    );

    test(
      'old logout sends the old token and preserves a newer credential',
      () async {
        final storage = _FakeDeviceCredentialStorage()
          ..credential = _deviceCredential()
          ..accessToken = 'access-1'
          ..tokenCommitted = true;
        final releaseLogout = Completer<void>();
        final remoteDataSource = _FakeRotatingAuthRemoteDataSource(
          refreshResult: const FailureResult(AuthenticationFailure()),
          logoutBlocker: releaseLogout,
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final oldLogout = repository.logout();
        await remoteDataSource.logoutStarted.future;
        storage
          ..credential = _deviceCredential(
            accessToken: 'access-new',
            refreshToken: 'refresh-new',
            sessionId: 'session-new',
          )
          ..accessToken = 'access-new';
        releaseLogout.complete();
        await oldLogout;

        expect(remoteDataSource.lastLogoutAccessToken, 'access-1');
        expect(storage.credential?.sessionId, 'session-new');
        expect(await storage.readAccessToken(), 'access-new');
        expect(storage.pendingAccountId, isNull);
      },
    );

    test(
      'restoreSession rebuilds session from stored token and backend data',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'stored-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const Success<AppUserModel>(
            AppUserModel(
              id: 7,
              username: 'alice',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        final session = result.when(
          success: (session) => session,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(session?.accessToken, 'stored-token');
        expect(session?.user.username, 'alice');
        expect(session?.currentWarehouse?.code, 'WH001');
        expect(remoteDataSource.loadCurrentUserCallCount, 1);
        expect(remoteDataSource.loadWarehousesCallCount, 1);
      },
    );

    test(
      'restoreSession skips backend calls when no token is stored',
      () async {
        final storage = _FakeTokenStorage();
        final remoteDataSource = _FakeAuthRemoteDataSource();
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        final session = result.when(
          success: (session) => session,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(session, isNull);
        expect(remoteDataSource.loadCurrentUserCallCount, 0);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test(
      'restoreSession delegates expired token cleanup after backend 401',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'expired-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const FailureResult<AppUserModel>(
            AuthenticationFailure(message: '登录已过期', businessCode: 10001),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<AuthenticationFailure>(),
        );
        expect(storage.accessToken, 'expired-token');
        expect(storage.clearCallCount, 0);
      },
    );

    test(
      'restoreSession delegates revoked token cleanup after backend 403',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'revoked-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const FailureResult<AppUserModel>(
            AuthorizationFailure(statusCode: 403),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<AuthorizationFailure>(),
        );
        expect(storage.accessToken, 'revoked-token');
        expect(storage.clearCallCount, 0);
      },
    );

    test(
      'restoreSession delegates warehouse 403 cleanup without losing its classification',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'revoked-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const Success<AppUserModel>(
            AppUserModel(
              id: 7,
              username: 'alice',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const FailureResult<List<WarehouseModel>>(
            AuthorizationFailure(statusCode: 403),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<AuthorizationFailure>(),
        );
        expect(storage.accessToken, 'revoked-token');
        expect(storage.clearCallCount, 0);
      },
    );

    test(
      'restoreSession preserves token when backend is unreachable',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'stored-token');
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeAuthRemoteDataSource(
            currentUserResult: const FailureResult<AppUserModel>(
              NetworkFailure(message: 'offline'),
            ),
          ),
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(result, isA<FailureResult<AuthSession?>>());
        expect(storage.accessToken, 'stored-token');
        expect(storage.clearCallCount, 0);
      },
    );

    test(
      'restoreSession clears token when current user has no username',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'stored-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const Success<AppUserModel>(
            AppUserModel(
              id: 7,
              username: '',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(result.isFailure, isTrue);
        final failure = result.when(
          success: (_) => throw TestFailure('restore should fail'),
          failure: (failure) => failure,
        );
        expect(failure, isA<UnknownFailure>());
        expect(failure.message, '用户信息缺少账号');
        expect(storage.accessToken, isNull);
        expect(storage.clearCallCount, 1);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test(
      'login rejects empty token without saving or loading warehouses',
      () async {
        final storage = _FakeTokenStorage();
        final remoteDataSource = _FakeAuthRemoteDataSource(
          loginResult: const Success<LoginResponseModel>(
            LoginResponseModel(
              token: '',
              user: AppUserModel(
                id: 7,
                username: 'alice',
                realName: 'Alice',
                roleCode: 'user',
                roleName: '普通用户',
              ),
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(result.isFailure, isTrue);
        final failure = result.when(
          success: (_) => throw TestFailure('login should fail'),
          failure: (failure) => failure,
        );
        expect(failure, isA<UnknownFailure>());
        expect(failure.message, '登录响应缺少 token');
        expect(storage.accessToken, isNull);
        expect(storage.saveCallCount, 0);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test('login bootstraps warehouses with only the response token', () async {
      final storage = _FakeTokenStorage(accessToken: 'old-invalid-token');
      final remoteDataSource = _FakeAuthRemoteDataSource(
        loginResult: const Success<LoginResponseModel>(
          LoginResponseModel(
            token: 'fresh-login-token',
            user: AppUserModel(
              id: 7,
              username: 'alice',
              realName: 'Alice',
              roleCode: 'user',
              roleName: 'User',
            ),
          ),
        ),
        warehousesResult: const Success<List<WarehouseModel>>([
          WarehouseModel(
            id: 1,
            code: 'WH001',
            name: 'Warehouse',
            isDefault: true,
          ),
        ]),
      );
      final repository = AuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: storage,
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result, isA<Success<AuthSession>>());
      expect(remoteDataSource.lastWarehouseAccessToken, 'fresh-login-token');
      expect(
        remoteDataSource.lastWarehouseAccessToken,
        isNot('old-invalid-token'),
      );
      expect(storage.ownerId, isNotNull);
      expect(storage.ownerId, isNotEmpty);
    });

    test(
      'raw login keeps its token pending until warehouse bootstrap succeeds',
      () async {
        final storage = _FakeTokenStorage();
        final warehouseBlocker = Completer<void>();
        final remoteDataSource = _FakeAuthRemoteDataSource(
          loginResult: const Success(
            LoginResponseModel(
              token: 'fresh-token',
              user: AppUserModel(
                id: 7,
                username: 'alice',
                realName: 'Alice',
                roleCode: 'user',
                roleName: 'User',
              ),
            ),
          ),
          warehousesResult: const Success([
            WarehouseModel(
              id: 1,
              code: 'WH001',
              name: 'Warehouse',
              isDefault: true,
            ),
          ]),
          warehouseBlocker: warehouseBlocker,
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
          tokenOwnerFactory: () => 'raw-owner',
        );

        final login = repository.login(username: 'alice', password: 'secret');
        await remoteDataSource.warehouseStarted.future;

        expect(storage.accessToken, 'fresh-token');
        expect(await storage.readAccessToken(), isNull);
        warehouseBlocker.complete();
        expect(await login, isA<Success<AuthSession>>());
        expect(await storage.readAccessToken(), 'fresh-token');
        expect(storage.committedOwnerIds, ['raw-owner']);
      },
    );

    test(
      'raw login allocates its durable attempt before the remote response',
      () async {
        final storage = _FakeTokenStorage();
        final remoteDataSource = _DelayedLoginRemoteDataSource();
        final owners = ['owner-a', 'owner-b'].iterator;
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
          tokenOwnerFactory: () {
            owners.moveNext();
            return owners.current;
          },
        );

        final older = repository.login(username: 'alice', password: 'secret');
        await remoteDataSource.aliceStarted.future;
        expect(storage.latestAttemptVersion, 1);

        final newer = await repository.login(
          username: 'bob',
          password: 'secret',
        );
        expect(newer, isA<Success<AuthSession>>());
        expect(storage.latestAttemptVersion, 2);
        expect(storage.ownerId, 'owner-b');
        expect(await storage.readAccessToken(), 'same-token');

        remoteDataSource.releaseAlice.complete();
        expect(await older, isA<FailureResult<AuthSession>>());
        expect(storage.ownerId, 'owner-b');
        expect(await storage.readAccessToken(), 'same-token');
      },
    );

    test('login rejects user without username before saving token', () async {
      final storage = _FakeTokenStorage();
      final remoteDataSource = _FakeAuthRemoteDataSource(
        loginResult: const Success<LoginResponseModel>(
          LoginResponseModel(
            token: 'token-123',
            user: AppUserModel(
              id: 7,
              username: '',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
        ),
        warehousesResult: const Success<List<WarehouseModel>>([
          WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
        ]),
      );
      final repository = AuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: storage,
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result.isFailure, isTrue);
      final failure = result.when(
        success: (_) => throw TestFailure('login should fail'),
        failure: (failure) => failure,
      );
      expect(failure, isA<UnknownFailure>());
      expect(failure.message, '用户信息缺少账号');
      expect(storage.accessToken, isNull);
      expect(storage.saveCallCount, 0);
      expect(remoteDataSource.loadWarehousesCallCount, 0);
    });

    test(
      'failed warehouse bootstrap conditionally rolls back its login token',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'old-token');
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeAuthRemoteDataSource(
            loginResult: const Success(
              LoginResponseModel(
                token: 'login-token',
                user: AppUserModel(
                  id: 7,
                  username: 'alice',
                  realName: 'Alice',
                  roleCode: 'user',
                  roleName: 'User',
                ),
              ),
            ),
            warehousesResult: const FailureResult(
              NetworkFailure(message: 'bootstrap failed'),
            ),
          ),
          secureStorage: storage,
          tokenOwnerFactory: () => 'bootstrap-owner',
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(result, isA<FailureResult<AuthSession>>());
        expect(storage.accessToken, isNull);
        expect(storage.ownerClearAttempts, ['bootstrap-owner']);
      },
    );

    test(
      'token storage write failures are returned as typed failures',
      () async {
        final storage = _FakeTokenStorage()..failWrites = true;
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeAuthRemoteDataSource(
            loginResult: const Success(
              LoginResponseModel(
                token: 'login-token',
                user: AppUserModel(
                  id: 7,
                  username: 'alice',
                  realName: 'Alice',
                  roleCode: 'user',
                  roleName: 'User',
                ),
              ),
            ),
          ),
          secureStorage: storage,
          tokenOwnerFactory: () => 'raw-owner',
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<LocalStorageFailure>(),
        );
      },
    );

    test(
      'token commit failures are returned as typed failures and stay unreadable',
      () async {
        final storage = _FakeTokenStorage()..failCommits = true;
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeAuthRemoteDataSource(
            loginResult: const Success(
              LoginResponseModel(
                token: 'login-token',
                user: AppUserModel(
                  id: 7,
                  username: 'alice',
                  realName: 'Alice',
                  roleCode: 'user',
                  roleName: 'User',
                ),
              ),
            ),
            warehousesResult: const Success([]),
          ),
          secureStorage: storage,
          tokenOwnerFactory: () => 'raw-owner',
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<LocalStorageFailure>(),
        );
        expect(await storage.readAccessToken(), isNull);
      },
    );

    for (final readError in [
      const FormatException('malformed token record'),
      StateError('secure storage read failed'),
    ]) {
      test(
        'token read ${readError.runtimeType} becomes LocalStorageFailure',
        () async {
          final storage = _FakeTokenStorage()..readError = readError;
          final repository = AuthRepositoryImpl(
            remoteDataSource: _FakeAuthRemoteDataSource(),
            secureStorage: storage,
          );

          final result = await repository.restoreSession();

          expect(
            result.when(success: (_) => null, failure: (failure) => failure),
            isA<LocalStorageFailure>(),
          );
        },
      );
    }

    test(
      'failed bootstrap clear exception becomes LocalStorageFailure',
      () async {
        final storage = _FakeTokenStorage()..failClears = true;
        final repository = AuthRepositoryImpl(
          remoteDataSource: _FakeAuthRemoteDataSource(
            loginResult: const Success(
              LoginResponseModel(
                token: 'login-token',
                user: AppUserModel(
                  id: 7,
                  username: 'alice',
                  realName: 'Alice',
                  roleCode: 'user',
                  roleName: 'User',
                ),
              ),
            ),
            warehousesResult: const FailureResult(
              NetworkFailure(message: 'bootstrap failed'),
            ),
          ),
          secureStorage: storage,
          tokenOwnerFactory: () => 'raw-owner',
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(
          result.when(success: (_) => null, failure: (failure) => failure),
          isA<LocalStorageFailure>(),
        );
        expect(await storage.readAccessToken(), isNull);
      },
    );

    test(
      'switchCurrentWarehouse confirms target warehouse with backend',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'active-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          switchWarehouseResult: const Success<WarehouseModel>(
            WarehouseModel(id: 2, code: 'BJ', name: '北京仓', isDefault: false),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.switchCurrentWarehouse(
          const WarehouseModel(
            id: 2,
            code: 'BJ',
            name: '北京仓',
            isDefault: true,
          ).toEntity(),
        );

        final warehouse = result.when(
          success: (warehouse) => warehouse,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(warehouse.id, 2);
        expect(warehouse.name, '北京仓');
        expect(warehouse.isDefault, isTrue);
        expect(remoteDataSource.lastSwitchWarehouseId, 2);
      },
    );

    test(
      'switchCurrentWarehouse keeps selected warehouse when backend returns no payload',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'active-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          switchWarehouseResult: const Success<WarehouseModel?>(null),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.switchCurrentWarehouse(
          const WarehouseModel(
            id: 3,
            code: 'GZ',
            name: '广州仓',
            isDefault: false,
          ).toEntity(),
        );

        final warehouse = result.when(
          success: (warehouse) => warehouse,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(warehouse.id, 3);
        expect(warehouse.code, 'GZ');
        expect(warehouse.name, '广州仓');
        expect(warehouse.isDefault, isFalse);
        expect(remoteDataSource.lastSwitchWarehouseId, 3);
      },
    );
  });
}

class _FakeTokenStorage
    implements
        TokenStorage,
        ConditionalTokenStorage,
        AuthTokenTransactionStorage {
  _FakeTokenStorage({this.accessToken}) : tokenCommitted = accessToken != null;

  String? accessToken;
  int clearCallCount = 0;
  int saveCallCount = 0;
  final List<String> conditionalClearAttempts = [];
  final List<String> ownerClearAttempts = [];
  String? ownerId;
  int latestAttemptVersion = 0;
  int? tokenAttemptVersion;
  bool tokenCommitted;
  bool failWrites = false;
  bool failCommits = false;
  bool failClears = false;
  Object? readError;
  final List<String> committedOwnerIds = [];

  @override
  Future<void> clearAccessToken() async {
    if (failClears) throw StateError('token clear failed');
    clearCallCount += 1;
    accessToken = null;
    ownerId = null;
    tokenAttemptVersion = null;
    tokenCommitted = false;
  }

  @override
  Future<bool> clearAccessTokenIfMatches(String expectedToken) async {
    conditionalClearAttempts.add(expectedToken);
    if (accessToken != expectedToken) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> clearAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    ownerClearAttempts.add(ownerId);
    if (this.ownerId != ownerId || tokenAttemptVersion != attemptVersion) {
      return false;
    }
    await clearAccessToken();
    return true;
  }

  @override
  Future<int> beginAccessTokenAttempt(String ownerId) async {
    latestAttemptVersion += 1;
    return latestAttemptVersion;
  }

  @override
  Future<bool> clearPendingAccessToken() async {
    if (accessToken == null || tokenCommitted) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> commitAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    if (failCommits) throw StateError('token commit failed');
    if (latestAttemptVersion != attemptVersion ||
        this.ownerId != ownerId ||
        tokenAttemptVersion != attemptVersion ||
        accessToken == null) {
      return false;
    }
    tokenCommitted = true;
    committedOwnerIds.add(ownerId);
    return true;
  }

  @override
  Future<String?> readAccessToken() async {
    if (readError case final error?) throw error;
    return tokenCommitted ? accessToken : null;
  }

  @override
  Future<void> saveAccessToken(String token) async {
    if (failWrites) throw StateError('token write failed');
    saveCallCount += 1;
    accessToken = token;
    ownerId = null;
    tokenAttemptVersion = null;
    tokenCommitted = true;
  }

  @override
  Future<bool> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
    required int attemptVersion,
  }) async {
    if (failWrites) throw StateError('token write failed');
    if (attemptVersion != latestAttemptVersion) return false;
    saveCallCount += 1;
    accessToken = token;
    this.ownerId = ownerId;
    tokenAttemptVersion = attemptVersion;
    tokenCommitted = false;
    return true;
  }
}

final class _FakeDeviceCredentialStorage extends _FakeTokenStorage
    implements DeviceCredentialStorage, PendingRevocationStorage {
  DeviceCredential? credential;
  String? pendingAccountId;
  Object? pendingMarkerError;
  DeviceCredential? credentialBeforeNextClear;

  @override
  Future<void> clearAccessToken() async {
    credential = null;
    await super.clearAccessToken();
  }

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) async {
    if (failWrites) throw StateError('credential write failed');
    if (attemptVersion != latestAttemptVersion) return false;
    this.credential = credential;
    accessToken = credential.accessToken;
    this.ownerId = ownerId;
    tokenAttemptVersion = attemptVersion;
    tokenCommitted = false;
    saveCallCount += 1;
    return true;
  }

  @override
  Future<DeviceCredential?> readDeviceCredential() async =>
      tokenCommitted ? credential : null;

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async {
    final current = this.credential;
    if (current == null ||
        current.accountId != expectedAccountId ||
        current.sessionId != expectedSessionId ||
        current.generation != expectedGeneration) {
      return false;
    }
    this.credential = credential;
    accessToken = credential.accessToken;
    return true;
  }

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async {
    if (credentialBeforeNextClear case final replacement?) {
      credentialBeforeNextClear = null;
      credential = replacement;
      accessToken = replacement.accessToken;
      return false;
    }
    final current = credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    credential = null;
    await clearAccessToken();
    return true;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    pendingAccountId = null;
  }

  @override
  Future<String?> readPendingRevocationAccountId() async => pendingAccountId;

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async {
    if (pendingMarkerError case final error?) throw error;
    pendingAccountId = accountId;
  }
}

class _FakeAuthRemoteDataSource implements AuthRemoteDataSource {
  _FakeAuthRemoteDataSource({
    this.currentUserResult = const FailureResult<AppUserModel>(
      UnknownFailure(),
    ),
    this.warehousesResult = const FailureResult<List<WarehouseModel>>(
      UnknownFailure(),
    ),
    this.loginResult = const FailureResult<LoginResponseModel>(
      UnknownFailure(),
    ),
    this.switchWarehouseResult = const FailureResult<WarehouseModel?>(
      UnknownFailure(),
    ),
    this.warehouseBlocker,
  });

  final Result<AppUserModel> currentUserResult;
  final Result<List<WarehouseModel>> warehousesResult;
  final Result<LoginResponseModel> loginResult;
  final Result<WarehouseModel?> switchWarehouseResult;
  final Completer<void>? warehouseBlocker;
  final Completer<void> warehouseStarted = Completer<void>();
  int loadCurrentUserCallCount = 0;
  int loadWarehousesCallCount = 0;
  int? lastSwitchWarehouseId;

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async {
    loadCurrentUserCallCount += 1;
    return currentUserResult;
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async {
    lastWarehouseAccessToken = accessToken;
    loadWarehousesCallCount += 1;
    if (!warehouseStarted.isCompleted) warehouseStarted.complete();
    await warehouseBlocker?.future;
    return warehousesResult;
  }

  String? lastWarehouseAccessToken;

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async {
    lastSwitchWarehouseId = warehouseId;
    return switchWarehouseResult;
  }

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async {
    return loginResult;
  }
}

final class _FakeRotatingAuthRemoteDataSource extends _FakeAuthRemoteDataSource
    implements RotatingAuthRemoteDataSource {
  _FakeRotatingAuthRemoteDataSource({
    required this.refreshResult,
    this.logoutResult = const Success(null),
    this.refreshBlocker,
    this.logoutBlocker,
  });

  final Result<LoginResponseModel> refreshResult;
  final Result<void> logoutResult;
  final Completer<void>? refreshBlocker;
  final Completer<void>? logoutBlocker;
  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> logoutStarted = Completer<void>();
  String? lastRefreshToken;
  String? lastLogoutAccessToken;
  int logoutCalls = 0;

  @override
  Future<Result<LoginResponseModel>> refresh({
    required String refreshToken,
  }) async {
    lastRefreshToken = refreshToken;
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    await refreshBlocker?.future;
    return refreshResult;
  }

  @override
  Future<Result<void>> logout({required String accessToken}) async {
    logoutCalls += 1;
    lastLogoutAccessToken = accessToken;
    if (!logoutStarted.isCompleted) logoutStarted.complete();
    await logoutBlocker?.future;
    return logoutResult;
  }
}

final class _DelayedLoginRemoteDataSource implements AuthRemoteDataSource {
  final Completer<void> aliceStarted = Completer<void>();
  final Completer<void> releaseAlice = Completer<void>();

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async {
    if (username == 'alice') {
      aliceStarted.complete();
      await releaseAlice.future;
    }
    return Success(
      LoginResponseModel(
        token: 'same-token',
        user: AppUserModel(
          id: username == 'alice' ? 7 : 8,
          username: username,
          realName: username,
          roleCode: 'user',
          roleName: 'User',
        ),
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
  Future<Result<AppUserModel>> loadCurrentUser() async =>
      const FailureResult(UnknownFailure());

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async => const FailureResult(UnknownFailure());
}

LoginResponseModel _rotatingLoginModel({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  int tokenVersion = 5,
}) => LoginResponseModel(
  token: accessToken,
  accessToken: accessToken,
  refreshToken: refreshToken,
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: tokenVersion,
  session: DeviceSessionModel(
    id: 'session-7',
    deviceLabel: 'Tablet',
    platform: 'android',
    userAgentFamily: 'RIMS',
    createdAt: DateTime.utc(2026, 7, 15, 2),
    lastUsedAt: DateTime.utc(2026, 7, 15, 2, 1),
    expiresAt: DateTime.utc(2026, 8, 14, 2),
    current: true,
  ),
  user: const AppUserModel(
    id: 7,
    username: 'alice',
    realName: 'Alice',
    roleCode: 'operator',
    roleName: 'Operator',
  ),
);

DeviceCredential _deviceCredential({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  String sessionId = 'session-7',
  int generation = 1,
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: '7',
  sessionId: sessionId,
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 5,
  generation: generation,
  biometricPolicy: BiometricCredentialPolicy.requireUnlock,
);
