import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/login_view_model.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

import '../../support/unsupported_device_sessions.dart';

void main() {
  group('LoginViewModel', () {
    test('rejects empty credentials', () async {
      final sessionController = AuthSessionController();
      final repository = _FakeAuthRepository();
      final viewModel = LoginViewModel(
        authRepository: repository,
        sessionController: sessionController,
      );

      final success = await viewModel.login();

      expect(success, isFalse);
      expect(viewModel.errorMessage, '请输入账号和密码');
      expect(sessionController.isAuthenticated, isFalse);
      expect(repository.loginCallCount, 0);
    });

    test(
      'does not treat slash-separated username as password shortcut',
      () async {
        final sessionController = AuthSessionController();
        final repository = _FakeAuthRepository();
        final viewModel = LoginViewModel(
          authRepository: repository,
          sessionController: sessionController,
        )..updateUsername('alice/secret');

        final success = await viewModel.login();

        expect(success, isFalse);
        expect(viewModel.errorMessage, '请输入账号和密码');
        expect(sessionController.isAuthenticated, isFalse);
        expect(repository.loginCallCount, 0);
      },
    );

    test('starts session after successful backend login', () async {
      final sessionController = AuthSessionController();
      final repository = _FakeAuthRepository(
        result: Success<AuthSession>(_session),
      );
      final viewModel =
          LoginViewModel(
              authRepository: repository,
              sessionController: sessionController,
            )
            ..updateUsername('admin')
            ..updatePassword('valid-password');

      final success = await viewModel.login();

      expect(success, isTrue);
      expect(viewModel.errorMessage, isNull);
      expect(sessionController.isAuthenticated, isTrue);
      expect(sessionController.currentUser?.realName, '系统管理员');
      expect(sessionController.currentWarehouse?.name, '上海仓');
      expect(sessionController.accessToken, 'token-123');
      expect(repository.lastUsername, 'admin');
      expect(repository.lastPassword, 'valid-password');
    });

    test(
      'transactional login commits only after controller acceptance',
      () async {
        late final AuthSessionController sessionController;
        late final _FakeAuthSessionTransaction transaction;
        transaction = _FakeAuthSessionTransaction(
          onCommit: () {
            transaction.commitObservedAcceptedSession =
                sessionController.session == _session;
          },
        );
        final repository = _TransactionalAuthRepository(
          transaction: transaction,
        );
        sessionController = AuthSessionController();
        final viewModel =
            LoginViewModel(
                authRepository: repository,
                sessionController: sessionController,
              )
              ..updateUsername('admin')
              ..updatePassword('valid-password');

        expect(await viewModel.login(), isTrue);

        expect(repository.prepareCalls, 1);
        expect(repository.loginCalls, 0);
        expect(transaction.commitCalls, 1);
        expect(transaction.abortCalls, 0);
        expect(transaction.commitObservedAcceptedSession, isFalse);
        expect(sessionController.session, _session);
      },
    );

    test(
      'ownership failure aborts a prepared login without committing',
      () async {
        final transaction = _FakeAuthSessionTransaction();
        final repository = _TransactionalAuthRepository(
          transaction: transaction,
        );
        final sessionController = AuthSessionController(
          ownershipCoordinator: const _FailingOwnershipCoordinator(),
        );
        final viewModel =
            LoginViewModel(
                authRepository: repository,
                sessionController: sessionController,
              )
              ..updateUsername('admin')
              ..updatePassword('valid-password');

        expect(await viewModel.login(), isFalse);

        expect(transaction.commitCalls, 0);
        expect(transaction.abortCalls, 1);
        expect(sessionController.session, isNull);
        expect(viewModel.errorMessage, contains('ownership failed'));
      },
    );

    test(
      'superseded controller epoch aborts a delayed prepared login',
      () async {
        final prepared = Completer<Result<AuthSessionTransaction>>();
        final transaction = _FakeAuthSessionTransaction();
        final repository = _TransactionalAuthRepository(
          transaction: transaction,
          prepared: prepared.future,
        );
        final sessionController = AuthSessionController();
        final viewModel =
            LoginViewModel(
                authRepository: repository,
                sessionController: sessionController,
              )
              ..updateUsername('admin')
              ..updatePassword('valid-password');

        final login = viewModel.login();
        while (repository.prepareCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        sessionController.beginAuthenticationAttempt();
        prepared.complete(Success(transaction));

        expect(await login, isFalse);
        expect(transaction.commitCalls, 0);
        expect(transaction.abortCalls, 1);
        expect(sessionController.session, isNull);
      },
    );

    for (final commitThrows in [false, true]) {
      test('commit ${commitThrows ? 'throw' : 'failure'} revokes the accepted '
          'session and reports a typed UI failure', () async {
        final transaction = _FakeAuthSessionTransaction(
          commitResult: const FailureResult<void>(
            LocalStorageFailure(message: 'credential commit failed'),
          ),
          throwOnCommit: commitThrows,
        );
        final repository = _TransactionalAuthRepository(
          transaction: transaction,
        );
        final sessionController = AuthSessionController();
        final viewModel =
            LoginViewModel(
                authRepository: repository,
                sessionController: sessionController,
              )
              ..updateUsername('admin')
              ..updatePassword('valid-password');

        expect(await viewModel.login(), isFalse);

        expect(transaction.commitCalls, 1);
        expect(transaction.abortCalls, 1);
        expect(sessionController.session, isNull);
        expect(sessionController.canAuthenticateRequests, isFalse);
        expect(viewModel.errorMessage, contains('credential commit failed'));
      });
    }

    for (final asynchronous in [false, true]) {
      test(
        'ownership finalize ${asynchronous ? 'async' : 'sync'} throw is contained and abort stays typed',
        () async {
          final transaction = _ThrowingOwnershipPreparedTransaction(
            asynchronous: asynchronous,
          );
          final controller = AuthSessionController();
          addTearDown(controller.dispose);
          final epoch = controller.beginAuthenticationAttempt();

          expect(
            await controller.startSession(
              transaction.session,
              expectedEpoch: epoch,
              transaction: transaction,
            ),
            isFalse,
          );

          expect(transaction.commitCalls, 1);
          expect(transaction.abortCalls, 1);
          expect(controller.session, isNull);
          expect(controller.canAuthenticateRequests, isFalse);
          expect(controller.ownershipFailure, isA<LocalStorageFailure>());
        },
      );
    }

    for (final invalidation in ['revoked', 'expired']) {
      test(
        '$invalidation invalidation waits for an active session commit',
        () async {
          final blocker = Completer<void>();
          final transaction = _FakeAuthSessionTransaction(
            commitResult: const FailureResult<void>(
              LocalStorageFailure(message: 'late commit failed'),
            ),
            commitBlocker: blocker,
          );
          final controller = AuthSessionController();
          await controller.startSession(_session);
          final epoch = controller.beginAuthenticationAttempt();

          final starting = controller.startSession(
            _beijingActiveSession,
            expectedEpoch: epoch,
            transaction: transaction,
          );
          await transaction.commitStarted.future;
          final invalidating = invalidation == 'revoked'
              ? controller.invalidateRevokedSession()
              : controller.invalidateExpiredSession();
          await Future<void>.delayed(Duration.zero);
          expect(controller.session, _session);
          blocker.complete();

          expect(await starting, isFalse);
          await invalidating;
          expect(controller.session, isNull);
          expect(
            controller.restoreFailure,
            invalidation == 'revoked'
                ? isA<AuthorizationFailure>()
                : isA<AuthenticationFailure>(),
          );
          expect(
            controller.sessionMessage,
            isNot(contains('late commit failed')),
          );
        },
      );
    }

    test('a newer session waits for an active commit to finish', () async {
      final blocker = Completer<void>();
      final transaction = _FakeAuthSessionTransaction(
        throwOnCommit: true,
        commitBlocker: blocker,
      );
      final controller = AuthSessionController();
      await controller.startSession(_session);
      final epoch = controller.beginAuthenticationAttempt();
      final stale = controller.startSession(
        _beijingActiveSession,
        expectedEpoch: epoch,
        transaction: transaction,
      );
      await transaction.commitStarted.future;

      final newer = controller.startSession(_multiWarehouseSession);
      var newerCompleted = false;
      unawaited(newer.then((_) => newerCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(newerCompleted, isFalse);
      blocker.complete();

      expect(await stale, isFalse);
      expect(await newer, isTrue);
      expect(controller.session, _multiWarehouseSession);
      expect(
        controller.ownershipFailure?.message,
        isNot('credential commit failed'),
      );
    });

    test('disposed controller ignores a late commit failure', () async {
      final blocker = Completer<void>();
      final transaction = _FakeAuthSessionTransaction(
        commitResult: const FailureResult<void>(
          LocalStorageFailure(message: 'late commit failed'),
        ),
        commitBlocker: blocker,
      );
      final controller = AuthSessionController();
      final epoch = controller.beginAuthenticationAttempt();
      final starting = controller.startSession(
        _session,
        expectedEpoch: epoch,
        transaction: transaction,
      );
      await transaction.commitStarted.future;
      controller.dispose();

      blocker.complete();

      expect(await starting, isFalse);
      expect(transaction.abortCalls, 1);
    });

    test('shows backend failure message for invalid credentials', () async {
      final sessionController = AuthSessionController();
      final repository = _FakeAuthRepository(
        result: const FailureResult<AuthSession>(
          AuthenticationFailure(message: '用户名或密码错误', businessCode: 10001),
        ),
      );
      final viewModel =
          LoginViewModel(
              authRepository: repository,
              sessionController: sessionController,
            )
            ..updateUsername('admin')
            ..updatePassword('wrong');

      final success = await viewModel.login();

      expect(success, isFalse);
      expect(viewModel.errorMessage, '用户名或密码错误');
      expect(sessionController.isAuthenticated, isFalse);
    });

    test('logout clears active session', () async {
      final sessionController = AuthSessionController();
      await sessionController.startSession(_session);

      await sessionController.logout(authRepository: _FakeAuthRepository());

      expect(sessionController.isAuthenticated, isFalse);
      expect(sessionController.currentUser, isNull);
      expect(sessionController.currentWarehouse, isNull);
      expect(sessionController.accessToken, isNull);
    });

    test(
      'accepted transactional session keeps its prepared auth epoch',
      () async {
        final sessionController = AuthSessionController();
        final preparedEpoch = sessionController.beginAuthenticationAttempt();

        expect(
          await sessionController.startSession(
            _session,
            expectedEpoch: preparedEpoch,
          ),
          isTrue,
        );

        expect(sessionController.authEpoch, preparedEpoch);
      },
    );

    test(
      'logout closes the authentication gate before remote cleanup',
      () async {
        final releaseLogout = Completer<void>();
        final repository = _FakeAuthRepository(
          logoutFuture: releaseLogout.future,
        );
        final sessionController = AuthSessionController();
        await sessionController.startSession(_session);
        var notifications = 0;
        sessionController.addListener(() => notifications += 1);

        final logout = sessionController.logout(authRepository: repository);
        await Future<void>.delayed(Duration.zero);

        expect(sessionController.canAuthenticateRequests, isFalse);
        expect(notifications, greaterThan(0));
        releaseLogout.complete();
        await logout;
      },
    );

    test('a newer session waits for an old logout to complete', () async {
      final releaseLogout = Completer<void>();
      final repository = _FakeAuthRepository(
        logoutFuture: releaseLogout.future,
      );
      final sessionController = AuthSessionController();
      await sessionController.startSession(_session);

      final logout = sessionController.logout(authRepository: repository);
      await Future<void>.delayed(Duration.zero);
      final newer = sessionController.startSession(_newSession);
      var newerCompleted = false;
      unawaited(newer.then((_) => newerCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(newerCompleted, isFalse);
      releaseLogout.complete();
      await logout;
      expect(await newer, isTrue);

      expect(sessionController.session, _newSession);
      expect(sessionController.canAuthenticateRequests, isTrue);
    });

    test(
      'logout keeps the real session and repository credentials until ownership cleanup succeeds',
      () async {
        final ownership = OfflineOwnershipService(
          store: const _EmptyOwnershipStore(),
          files: _RetryingOwnedFiles(),
          scans: const _EmptyOwnedScans(),
          reviews: const _EmptyReviewInvalidator(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
        );
        final repository = _FakeAuthRepository();
        final sessionController = AuthSessionController(
          ownershipCoordinator: ownership,
        );
        await sessionController.startSession(_session);

        final failed = await sessionController.logout(
          authRepository: repository,
        );

        expect(failed?.completed, isFalse);
        expect(repository.logoutCallCount, 0);
        expect(sessionController.session, _session);
        expect(sessionController.accessToken, _session.accessToken);
        expect(sessionController.ownershipFailure, isNotNull);
        expect(
          sessionController.ownershipFailure?.message,
          contains('Unable to clear account offline files.'),
        );

        final retried = await sessionController.logout(
          authRepository: repository,
        );

        expect(retried?.completed, isTrue);
        expect(repository.logoutCallCount, 1);
        expect(sessionController.session, isNull);
        expect(sessionController.accessToken, isNull);
        expect(sessionController.ownershipFailure, isNull);
      },
    );

    test(
      'restoreSession exposes restoring state and starts restored session',
      () async {
        final completer = Completer<Result<AuthSession?>>();
        final sessionController = AuthSessionController();
        final repository = _FakeAuthRepository(restoreFuture: completer.future);

        final restore = sessionController.restoreSession(repository);

        await Future<void>.delayed(Duration.zero);
        expect(sessionController.isRestoring, isTrue);
        completer.complete(const Success<AuthSession?>(_session));
        await restore;

        expect(sessionController.isRestoring, isFalse);
        expect(sessionController.restoreFailure, isNull);
        expect(sessionController.isAuthenticated, isTrue);
        expect(sessionController.currentUser?.username, 'admin');
        expect(repository.restoreCallCount, 1);
      },
    );

    test(
      'restoreSession clears session and exposes failure when restore fails',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_session);
        final repository = _FakeAuthRepository(
          restoreResult: const FailureResult<AuthSession?>(
            AuthenticationFailure(message: '登录已过期', businessCode: 10001),
          ),
        );

        await sessionController.restoreSession(repository);

        expect(sessionController.isRestoring, isFalse);
        expect(sessionController.isAuthenticated, isFalse);
        expect(sessionController.restoreFailure?.message, '登录已过期');
      },
    );

    test(
      'refreshSession preserves active session when background restore fails',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_session);
        final repository = _FakeAuthRepository(
          restoreResult: const FailureResult<AuthSession?>(
            NetworkFailure(message: '刷新失败'),
          ),
        );

        await sessionController.refreshSession(repository);

        expect(sessionController.isRestoring, isFalse);
        expect(sessionController.isAuthenticated, isTrue);
        expect(sessionController.currentUser?.username, 'admin');
        expect(sessionController.restoreFailure?.message, '刷新失败');
        expect(sessionController.sessionMessage, '刷新失败');
      },
    );

    test(
      'refreshSession preserves active warehouse when backend omits current marker',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_beijingActiveSession);
        final repository = _FakeAuthRepository(
          restoreResult: const Success<AuthSession?>(_multiWarehouseSession),
        );

        await sessionController.refreshSession(repository);

        expect(sessionController.isAuthenticated, isTrue);
        expect(sessionController.currentWarehouse?.id, 2);
        expect(sessionController.currentWarehouse?.name, '北京仓');
      },
    );

    test(
      'refreshSession clears active session when authentication fails',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_session);
        final repository = _FakeAuthRepository(
          restoreResult: const FailureResult<AuthSession?>(
            AuthenticationFailure(message: '登录已过期', businessCode: 10001),
          ),
        );

        await sessionController.refreshSession(repository);

        expect(sessionController.isRestoring, isFalse);
        expect(sessionController.isAuthenticated, isFalse);
        expect(sessionController.currentUser, isNull);
        expect(sessionController.restoreFailure?.message, '登录已过期');
        expect(sessionController.sessionMessage, '登录已过期');
      },
    );

    test(
      'refreshSession recovers from a thrown repository exception without leaving an old token usable',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_session);
        final repository = _FakeAuthRepository(
          restoreFuture: Future<Result<AuthSession?>>.error(
            StateError('secure storage failed'),
          ),
        );

        await sessionController.refreshSession(repository);

        expect(sessionController.isRestoring, isFalse);
        expect(sessionController.session, isNull);
        expect(sessionController.accessToken, isNull);
        expect(sessionController.canAuthenticateRequests, isFalse);
        expect(sessionController.restoreFailure, isA<LocalStorageFailure>());
        expect(sessionController.restoreFailure?.message, contains('会话恢复失败'));
      },
    );

    test(
      'switchWarehouse updates current warehouse after backend confirms it',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_multiWarehouseSession);
        final repository = _FakeAuthRepository(
          switchWarehouseResult: const Success<Warehouse>(_beijingWarehouse),
        );

        final success = await sessionController.switchWarehouse(
          authRepository: repository,
          warehouse: _beijingWarehouse,
        );

        expect(success, isTrue);
        expect(sessionController.currentWarehouse?.id, 2);
        expect(sessionController.currentWarehouse?.name, '北京仓');
        expect(sessionController.switchWarehouseFailure, isNull);
        expect(repository.lastSwitchWarehouseId, 2);
      },
    );

    test(
      'switchWarehouse keeps current warehouse when backend rejects it',
      () async {
        final sessionController = AuthSessionController();
        await sessionController.startSession(_multiWarehouseSession);
        final repository = _FakeAuthRepository(
          switchWarehouseResult: const FailureResult<Warehouse>(
            AuthorizationFailure(message: '无权访问该仓库'),
          ),
        );

        final success = await sessionController.switchWarehouse(
          authRepository: repository,
          warehouse: _beijingWarehouse,
        );

        expect(success, isFalse);
        expect(sessionController.currentWarehouse?.id, 1);
        expect(sessionController.currentWarehouse?.name, '上海仓');
        expect(sessionController.switchWarehouseFailure?.message, '无权访问该仓库');
      },
    );

    test(
      'switchWarehouse contains thrown storage errors and can retry',
      () async {
        final controller = AuthSessionController();
        await controller.startSession(_multiWarehouseSession);
        final failed = await controller.switchWarehouse(
          authRepository: _FakeAuthRepository(
            switchFuture: Future.error(StateError('storage failed')),
          ),
          warehouse: _beijingWarehouse,
        );
        expect(failed, isFalse);
        expect(controller.isSwitchingWarehouse, isFalse);
        expect(controller.switchWarehouseFailure, isA<LocalStorageFailure>());

        final retried = await controller.switchWarehouse(
          authRepository: _FakeAuthRepository(
            switchWarehouseResult: const Success(_beijingWarehouse),
          ),
          warehouse: _beijingWarehouse,
        );
        expect(retried, isTrue);
      },
    );

    test('logout waits for a blocked restore then clears its result', () async {
      final controller = AuthSessionController();
      await controller.startSession(_session);
      final blocked = Completer<Result<AuthSession?>>();
      final restore = controller.refreshSession(
        _FakeAuthRepository(restoreFuture: blocked.future),
      );
      await Future<void>.delayed(Duration.zero);
      final logout = controller.logout(authRepository: _FakeAuthRepository());
      var logoutCompleted = false;
      unawaited(logout.then((_) => logoutCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(logoutCompleted, isFalse);
      blocked.complete(const Success<AuthSession?>(_session));
      await restore;
      await logout;

      expect(controller.session, isNull);
      expect(controller.canAuthenticateRequests, isFalse);
      expect(controller.isRestoring, isFalse);
    });

    test(
      'session context generation changes only after ownership changes',
      () async {
        final sessionController = AuthSessionController();
        expect(sessionController.contextGeneration, 0);

        await sessionController.startSession(_multiWarehouseSession);
        expect(sessionController.contextGeneration, 1);

        await sessionController.switchWarehouse(
          authRepository: _FakeAuthRepository(
            switchWarehouseResult: const Success<Warehouse>(_warehouse),
          ),
          warehouse: _warehouse,
        );
        expect(sessionController.contextGeneration, 1);

        await sessionController.switchWarehouse(
          authRepository: _FakeAuthRepository(
            switchWarehouseResult: const Success<Warehouse>(_beijingWarehouse),
          ),
          warehouse: _beijingWarehouse,
        );
        expect(sessionController.contextGeneration, 2);

        await sessionController.logout(authRepository: _FakeAuthRepository());
        expect(sessionController.contextGeneration, 3);
      },
    );
  });
}

const _user = AppUser(
  id: 1,
  username: 'admin',
  realName: '系统管理员',
  roleCode: 'admin',
  roleName: '管理员',
);

const _warehouse = Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true);
const _beijingWarehouse = Warehouse(
  id: 2,
  code: 'BJ',
  name: '北京仓',
  isDefault: false,
);

const _session = AuthSession(
  accessToken: 'token-123',
  user: _user,
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);

const _newSession = AuthSession(
  accessToken: 'token-new',
  user: _user,
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);

const _multiWarehouseSession = AuthSession(
  accessToken: 'token-123',
  user: _user,
  currentWarehouse: _warehouse,
  warehouses: [_warehouse, _beijingWarehouse],
);

const _beijingActiveSession = AuthSession(
  accessToken: 'token-123',
  user: _user,
  currentWarehouse: _beijingWarehouse,
  warehouses: [_warehouse, _beijingWarehouse],
);

final class _FakeAuthRepository
    with UnsupportedDeviceSessions
    implements AuthRepository {
  _FakeAuthRepository({
    Result<AuthSession>? result,
    Result<AuthSession?>? restoreResult,
    this.switchWarehouseResult = const FailureResult<Warehouse>(
      UnknownFailure(),
    ),
    this.restoreFuture,
    this.switchFuture,
    this.logoutFuture,
  }) : _result = result ?? const FailureResult<AuthSession>(UnknownFailure()),
       _restoreResult =
           restoreResult ?? const FailureResult<AuthSession?>(UnknownFailure());

  final Result<AuthSession> _result;
  final Result<AuthSession?> _restoreResult;
  final Result<Warehouse> switchWarehouseResult;
  final Future<Result<AuthSession?>>? restoreFuture;
  final Future<Result<Warehouse>>? switchFuture;
  final Future<void>? logoutFuture;
  int loginCallCount = 0;
  int restoreCallCount = 0;
  int logoutCallCount = 0;
  int? lastSwitchWarehouseId;
  String? lastUsername;
  String? lastPassword;

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    loginCallCount += 1;
    lastUsername = username;
    lastPassword = password;
    return _result;
  }

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    restoreCallCount += 1;
    return restoreFuture ?? _restoreResult;
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    lastSwitchWarehouseId = warehouse.id;
    return switchFuture ?? switchWarehouseResult;
  }

  @override
  Future<void> logout() async {
    logoutCallCount += 1;
    await logoutFuture;
  }
}

final class _TransactionalAuthRepository
    with UnsupportedDeviceSessions
    implements AuthRepository, TransactionalAuthRepository {
  _TransactionalAuthRepository({required this.transaction, this.prepared});

  final AuthSessionTransaction transaction;
  final Future<Result<AuthSessionTransaction>>? prepared;
  int prepareCalls = 0;
  int loginCalls = 0;

  @override
  Future<Result<AuthSessionTransaction>> prepareLogin({
    required String username,
    required String password,
  }) async {
    prepareCalls += 1;
    return prepared ?? Success(transaction);
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    loginCalls += 1;
    return Success(transaction.session);
  }

  @override
  Future<void> logout() async {}

  @override
  Future<Result<AuthSession?>> restoreSession() async => const Success(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);
}

final class _FakeAuthSessionTransaction implements AuthSessionTransaction {
  _FakeAuthSessionTransaction({
    this.commitResult = const Success<void>(null),
    this.throwOnCommit = false,
    this.onCommit,
    this.commitBlocker,
  });

  final Result<void> commitResult;
  final bool throwOnCommit;
  final void Function()? onCommit;
  final Completer<void>? commitBlocker;
  final Completer<void> commitStarted = Completer<void>();
  int commitCalls = 0;
  int abortCalls = 0;
  bool commitObservedAcceptedSession = false;

  @override
  AuthSession get session => _session;

  @override
  Future<Result<void>> commit() async {
    commitCalls += 1;
    if (!commitStarted.isCompleted) commitStarted.complete();
    onCommit?.call();
    await commitBlocker?.future;
    if (throwOnCommit) throw StateError('credential commit failed');
    return commitResult;
  }

  @override
  Future<Result<void>> abort() async {
    abortCalls += 1;
    return const Success(null);
  }
}

final class _ThrowingOwnershipPreparedTransaction
    implements AuthSessionTransaction, OwnershipPreparedAuthSessionTransaction {
  _ThrowingOwnershipPreparedTransaction({required this.asynchronous});

  final bool asynchronous;
  int commitCalls = 0;
  int abortCalls = 0;

  @override
  bool get hasPreparedReauthentication => true;

  @override
  AuthSession get session => _session;

  @override
  Future<Result<void>> commit() async {
    commitCalls += 1;
    return const Success(null);
  }

  @override
  Future<Result<void>> finalizeReauthentication() {
    if (!asynchronous) throw StateError('sync finalize failed');
    return Future<Result<void>>.error(StateError('async finalize failed'));
  }

  @override
  Future<Result<void>> abort() {
    abortCalls += 1;
    if (!asynchronous) throw StateError('sync abort failed');
    return Future<Result<void>>.error(StateError('async abort failed'));
  }
}

final class _FailingOwnershipCoordinator
    implements OfflineOwnershipCoordinator {
  const _FailingOwnershipCoordinator();

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async =>
      OfflineOwnershipReport(
        reason: intent.reason,
        accountId: intent.accountId,
        executedCounts: const OfflineOwnershipCounts(),
        failures: const [
          OfflineOwnershipFailure(
            step: OfflineOwnershipStep.store,
            message: 'ownership failed',
          ),
        ],
      );

  @override
  bool canAccessOfflineData(String accountId) => false;

  @override
  bool canSync(String accountId) => false;
}

final class _EmptyOwnershipStore implements OfflineOwnershipStore {
  const _EmptyOwnershipStore();

  @override
  Future<void> clearAccountCache(String accountId) async {}

  @override
  Future<void> clearAccountOfflineWork(String accountId) async {}

  @override
  Future<void> clearAllSensitiveData() async {}

  @override
  Future<void> clearOwnedAccount(
    String accountId, {
    required bool preserveDrafts,
  }) async {}

  @override
  Future<void> discardSessionProjection(String accountId) async {}

  @override
  Future<void> invalidatePermissionScopedCache(String accountId) async {}

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) async {}

  @override
  Future<OfflineStoreOwnershipSnapshot> inspectAccount(
    String accountId,
  ) async => const OfflineStoreOwnershipSnapshot();
}

final class _RetryingOwnedFiles implements OfflineOwnedFileStore {
  int calls = 0;

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {
    calls += 1;
    if (calls == 1) throw StateError('staging cleanup failed');
  }

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

final class _EmptyOwnedScans implements OfflineOwnedScanStore {
  const _EmptyOwnedScans();

  @override
  Future<void> clearAllSessions() async {}

  @override
  Future<void> clearSessionsForAccount(String accountId) async {}

  @override
  Future<int> countForAccount(String accountId) async => 0;
}

final class _EmptyReviewInvalidator implements OfflineReviewInvalidator {
  const _EmptyReviewInvalidator();

  @override
  Future<void> invalidate({
    required String accountId,
    int? warehouseId,
  }) async {}
}
