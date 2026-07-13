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
      'restoreSession exposes restoring state and starts restored session',
      () async {
        final completer = Completer<Result<AuthSession?>>();
        final sessionController = AuthSessionController();
        final repository = _FakeAuthRepository(restoreFuture: completer.future);

        final restore = sessionController.restoreSession(repository);

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

final class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({
    Result<AuthSession>? result,
    Result<AuthSession?>? restoreResult,
    this.switchWarehouseResult = const FailureResult<Warehouse>(
      UnknownFailure(),
    ),
    this.restoreFuture,
  }) : _result = result ?? const FailureResult<AuthSession>(UnknownFailure()),
       _restoreResult =
           restoreResult ?? const FailureResult<AuthSession?>(UnknownFailure());

  final Result<AuthSession> _result;
  final Result<AuthSession?> _restoreResult;
  final Result<Warehouse> switchWarehouseResult;
  final Future<Result<AuthSession?>>? restoreFuture;
  int loginCallCount = 0;
  int restoreCallCount = 0;
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
    return switchWarehouseResult;
  }

  @override
  Future<void> logout() async {}
}
