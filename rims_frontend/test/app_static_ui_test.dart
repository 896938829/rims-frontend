import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/routes/app_router.dart';
import 'package:rims_frontend/routes/route_paths.dart';

void main() {
  testWidgets('app starts on login page', (tester) async {
    await _pumpApp(tester);

    expect(find.text('RIMS'), findsWidgets);
    expect(find.text('登录'), findsWidgets);
  });

  testWidgets('login page hides demo shortcuts', (tester) async {
    await _pumpApp(tester);

    expect(find.byIcon(Icons.admin_panel_settings_outlined), findsNothing);
    expect(find.byIcon(Icons.person_outline), findsNothing);
  });

  testWidgets('login entry opens 5-tab shell with active user context', (
    tester,
  ) async {
    await _pumpApp(tester);

    await _login(tester);

    expect(find.text('首页'), findsWidgets);
    expect(find.text('库存'), findsWidgets);
    expect(find.text('单据'), findsWidgets);
    expect(find.text('报表'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
    expect(find.text('Good morning, 系统管理员'), findsOneWidget);
    expect(find.text('库存预警'), findsOneWidget);
  });

  testWidgets('shell bottom navigation switches tab body', (tester) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-inventory')), findsOneWidget);
  });

  testWidgets('unauthenticated shell route redirects to login', (tester) async {
    await _pumpApp(tester, initialLocation: RoutePaths.shell);

    expect(find.text('登录'), findsWidgets);
  });

  testWidgets('profile logout returns to login page', (tester) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('退出登录'));
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsWidgets);
  });
}

Future<void> _pumpApp(
  WidgetTester tester, {
  String initialLocation = RoutePaths.login,
}) async {
  final sessionController = AuthSessionController();

  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: createAppRouter(
        authRepository: const _FakeAuthRepository(),
        sessionController: sessionController,
        initialLocation: initialLocation,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _login(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('login-username-field')),
    'admin',
  );
  await tester.enterText(
    find.byKey(const Key('login-password-field')),
    'valid-password',
  );
  await tester.ensureVisible(find.widgetWithText(FilledButton, '登录'));
  await tester.tap(find.widgetWithText(FilledButton, '登录'));
  await tester.pumpAndSettle();
}

const _session = AuthSession(
  accessToken: 'token-123',
  user: AppUser(
    id: 1,
    username: 'admin',
    realName: '系统管理员',
    roleCode: 'admin',
    roleName: '管理员',
  ),
  currentWarehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
  warehouses: [Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true)],
);

final class _FakeAuthRepository implements AuthRepository {
  const _FakeAuthRepository();

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    if (username == 'admin' && password == 'valid-password') {
      return const Success<AuthSession>(_session);
    }

    return const FailureResult<AuthSession>(
      AuthenticationFailure(message: '用户名或密码错误', businessCode: 10001),
    );
  }

  @override
  Future<void> logout() async {}
}
