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

    test('logout clears active session', () {
      final sessionController = AuthSessionController()..startSession(_session);

      sessionController.logout();

      expect(sessionController.isAuthenticated, isFalse);
      expect(sessionController.currentUser, isNull);
      expect(sessionController.currentWarehouse, isNull);
      expect(sessionController.accessToken, isNull);
    });
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

const _session = AuthSession(
  accessToken: 'token-123',
  user: _user,
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);

final class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({Result<AuthSession>? result})
    : _result = result ?? const FailureResult<AuthSession>(UnknownFailure());

  final Result<AuthSession> _result;
  int loginCallCount = 0;
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
  Future<void> logout() async {}
}
