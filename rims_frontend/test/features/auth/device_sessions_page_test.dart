import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/theme/app_theme.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/pages/device_sessions_page.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/profile/presentation/pages/profile_page.dart';
import 'package:rims_frontend/routes/app_router.dart';
import 'package:rims_frontend/routes/route_paths.dart';

void main() {
  testWidgets('shows safe metadata, exact current marker, and no precise IP', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(
      sessions: [_currentSession, _unknownSession],
    );
    await _pumpPage(tester, repository: repository);

    expect(find.text('Current tablet'), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);
    expect(find.text('RIMS Android 客户端'), findsOneWidget);
    expect(find.text('当前设备'), findsOneWidget);
    expect(find.text('未知设备'), findsOneWidget);
    expect(find.text('未知平台'), findsOneWidget);
    expect(find.text('未知客户端'), findsOneWidget);
    expect(find.textContaining('2026-07-15 09:30'), findsOneWidget);
    expect(find.textContaining('10.24.16.8'), findsNothing);
    expect(find.textContaining('IP'), findsNothing);
  });

  testWidgets(
    'redacts embedded network addresses from text semantics tooltip and dialog',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final repository = _FakeAuthRepository(
        sessions: [_ipv4LabelSession, _ipv6LabelSession, _ipv6PortLabelSession],
      );
      await _pumpPage(tester, repository: repository);

      expect(find.text('未知设备'), findsNWidgets(3));
      expect(find.text('Chrome 浏览器'), findsNWidgets(3));
      expect(find.byTooltip('撤销 未知设备'), findsNWidgets(3));
      final renderedText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .join(' ');
      final semanticsText = ['ipv4', 'ipv6', 'ipv6-port']
          .map((id) {
            return tester
                .getSemantics(find.byKey(Key('device-session-card-$id')))
                .toStringDeep();
          })
          .join(' ');

      for (final secret in [
        '10.24.16.8',
        '2001:db8::1',
        '2001:db8:85a3::8a2e:370:7334',
      ]) {
        expect(renderedText, isNot(contains(secret)));
        expect(semanticsText, isNot(contains(secret)));
      }

      await tester.tap(
        find.byKey(const Key('device-session-revoke-ipv6-port')),
      );
      await tester.pumpAndSettle();
      final confirmText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .join(' ');
      expect(confirmText, isNot(contains('2001:db8::1')));
      semantics.dispose();
    },
  );

  testWidgets('requires confirmation before revoking one device', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(
      sessions: [_currentSession, _otherSession],
    );
    await _pumpPage(tester, repository: repository);

    await tester.tap(find.byKey(const Key('device-session-revoke-s-2')));
    await tester.pumpAndSettle();
    expect(repository.revokeSessionCalls, isEmpty);
    expect(find.text('撤销此设备？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-sessions-confirm')));
    await tester.pumpAndSettle();
    expect(repository.revokeSessionCalls, ['s-2']);
    expect(repository.listCalls, 2);
    expect(find.text('已撤销 Warehouse tablet'), findsOneWidget);
  });

  testWidgets('revoke others and all are confirmed and share one busy gate', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(
      sessions: [_currentSession, _otherSession],
      holdRevokeOthers: true,
    );
    await _pumpPage(tester, repository: repository);

    await tester.tap(find.byKey(const Key('device-sessions-revoke-others')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-sessions-confirm')));
    await tester.pump();

    final revokeAll = tester.widget<OutlinedButton>(
      find.byKey(const Key('device-sessions-revoke-all')),
    );
    expect(revokeAll.onPressed, isNull);
    repository.releaseRevokeOthers();
    await tester.pumpAndSettle();
    expect(repository.revokeOthersCalls, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('device-sessions-revoke-all')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-sessions-revoke-all')));
    await tester.pumpAndSettle();
    expect(find.text('撤销全部设备？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-sessions-cancel')));
    await tester.pumpAndSettle();
    expect(repository.revokeAllCalls, 0);
  });

  testWidgets('current revoke runs revocation cleanup and redirects to login', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(sessions: [_currentSession]);
    final ownership = _RecordingOwnershipCoordinator();
    final controller = AuthSessionController(ownershipCoordinator: ownership);
    await controller.startSession(_authSession);
    ownership.reasons.clear();
    final router = GoRouter(
      initialLocation: RoutePaths.deviceSessions,
      refreshListenable: controller,
      redirect: (context, state) =>
          !controller.isAuthenticated ? RoutePaths.login : null,
      routes: [
        GoRoute(
          path: RoutePaths.login,
          builder: (context, state) => const Scaffold(body: Text('登录页')),
        ),
        GoRoute(
          path: RoutePaths.deviceSessions,
          builder: (context, state) => DeviceSessionsPage(
            authRepository: repository,
            sessionController: controller,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('device-session-revoke-s-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-sessions-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('登录页'), findsOneWidget);
    expect(repository.expireCredentialCalls, 1);
    expect(ownership.reasons, [OfflineOwnershipReason.revocation]);
  });

  testWidgets('revoke all runs revocation cleanup and redirects to login', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(
      sessions: [_currentSession, _otherSession],
    );
    final ownership = _RecordingOwnershipCoordinator();
    final controller = AuthSessionController(ownershipCoordinator: ownership);
    await controller.startSession(_authSession);
    ownership.reasons.clear();
    final router = GoRouter(
      initialLocation: RoutePaths.deviceSessions,
      refreshListenable: controller,
      redirect: (context, state) =>
          !controller.isAuthenticated ? RoutePaths.login : null,
      routes: [
        GoRoute(
          path: RoutePaths.login,
          builder: (context, state) => const Scaffold(body: Text('登录页')),
        ),
        GoRoute(
          path: RoutePaths.deviceSessions,
          builder: (context, state) => DeviceSessionsPage(
            authRepository: repository,
            sessionController: controller,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('device-sessions-revoke-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-sessions-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('登录页'), findsOneWidget);
    expect(repository.revokeAllCalls, 1);
    expect(repository.expireCredentialCalls, 1);
    expect(ownership.reasons, [OfflineOwnershipReason.revocation]);
  });

  testWidgets('retains content after refresh error and offers retry', (
    tester,
  ) async {
    final repository = _FakeAuthRepository(sessions: [_currentSession]);
    await _pumpPage(tester, repository: repository);
    repository.listFailure = const NetworkFailure();

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    expect(find.text('Current tablet'), findsOneWidget);
    expect(find.text('刷新登录设备失败，请重试'), findsOneWidget);
    expect(find.byKey(const Key('device-sessions-retry')), findsOneWidget);
  });

  testWidgets(
    'buttons expose semantics, keyboard activation, and 48dp targets',
    (tester) async {
      final repository = _FakeAuthRepository(
        sessions: [_currentSession, _otherSession],
      );
      await _pumpPage(tester, repository: repository);

      final revoke = find.byKey(const Key('device-session-revoke-s-2'));
      expect(find.bySemanticsLabel('撤销 Warehouse tablet'), findsOneWidget);
      expect(tester.getSize(revoke).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(revoke).height, greaterThanOrEqualTo(48));
      expect(tester.widget<IconButton>(revoke).onPressed, isNotNull);

      Focus.of(tester.element(revoke)).requestFocus();
      await tester.pump();
      expect(Focus.of(tester.element(revoke)).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('撤销此设备？'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'narrow large-text ${brightness.name} layout does not overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = _FakeAuthRepository(
          sessions: [_currentSession, _otherSession],
        );
        await _pumpPage(
          tester,
          repository: repository,
          brightness: brightness,
          textScaler: const TextScaler.linear(2),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('登录设备'), findsOneWidget);
        final card = tester.widget<Material>(
          find.byKey(const Key('device-session-card-s-1')),
        );
        expect(
          card.color,
          brightness == Brightness.dark
              ? AppTheme.dark.colorScheme.surface
              : AppTheme.light.colorScheme.surface,
        );
      },
    );
  }

  testWidgets('profile entry navigates to centralized device sessions route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: RoutePaths.shell,
      routes: [
        GoRoute(
          path: RoutePaths.shell,
          builder: (context, state) => const Scaffold(
            body: ProfilePage(user: _user, warehouse: _warehouse),
          ),
        ),
        GoRoute(
          path: RoutePaths.deviceSessions,
          builder: (context, state) => const Scaffold(body: Text('设备会话页')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-device-sessions-entry')),
      200,
    );
    await tester.tap(find.byKey(const Key('profile-device-sessions-entry')));
    await tester.pumpAndSettle();

    expect(find.text('设备会话页'), findsOneWidget);
  });

  testWidgets('central router protects device sessions route', (tester) async {
    final repository = _FakeAuthRepository(sessions: [_currentSession]);
    final controller = AuthSessionController();
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: createAppRouter(
          authRepository: repository,
          sessionController: controller,
          initialLocation: RoutePaths.deviceSessions,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    expect(find.text('Current tablet'), findsNothing);
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakeAuthRepository repository,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final controller = AuthSessionController();
  await controller.startSession(_authSession);
  final theme = brightness == Brightness.dark ? AppTheme.dark : AppTheme.light;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: DeviceSessionsPage(
          authRepository: repository,
          sessionController: controller,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _user = AppUser(
  id: 7,
  username: 'operator',
  realName: '仓库操作员',
  roleCode: 'operator',
  roleName: '操作员',
);

const _warehouse = Warehouse(
  id: 1,
  code: 'WH-01',
  name: '上海仓',
  isDefault: true,
);

const _authSession = AuthSession(
  accessToken: 'access-token',
  user: _user,
  currentWarehouse: _warehouse,
  warehouses: [_warehouse],
);

final _currentSession = DeviceSession(
  id: 's-1',
  deviceLabel: 'Current tablet',
  platform: 'android',
  userAgentFamily: 'RIMS Android',
  createdAt: DateTime.utc(2026, 7, 1, 8),
  lastUsedAt: DateTime.utc(2026, 7, 15, 9, 30),
  expiresAt: DateTime.utc(2026, 8, 1, 8),
  current: true,
);

final _otherSession = DeviceSession(
  id: 's-2',
  deviceLabel: 'Warehouse tablet',
  platform: 'windows',
  userAgentFamily: 'Chrome',
  createdAt: DateTime.utc(2026, 7, 2, 8),
  lastUsedAt: DateTime.utc(2026, 7, 14, 10, 45),
  expiresAt: DateTime.utc(2026, 8, 2, 8),
  current: false,
);

final _unknownSession = DeviceSession(
  id: 's-3',
  deviceLabel: ' ',
  platform: ' ',
  userAgentFamily: 'unknown',
  createdAt: DateTime.utc(2026, 7, 3, 8),
  lastUsedAt: DateTime.utc(2026, 7, 13, 8),
  expiresAt: DateTime.utc(2026, 8, 3, 8),
  current: false,
);

final _ipv4LabelSession = DeviceSession(
  id: 'ipv4',
  deviceLabel: 'Scanner 10.24.16.8:8443 primary',
  platform: 'windows',
  userAgentFamily: 'Chrome',
  createdAt: DateTime.utc(2026, 7, 3, 8),
  lastUsedAt: DateTime.utc(2026, 7, 13, 8),
  expiresAt: DateTime.utc(2026, 8, 3, 8),
  current: false,
);

final _ipv6LabelSession = DeviceSession(
  id: 'ipv6',
  deviceLabel: 'Scanner 2001:db8:85a3::8a2e:370:7334 primary',
  platform: 'windows',
  userAgentFamily: 'Chrome',
  createdAt: DateTime.utc(2026, 7, 3, 8),
  lastUsedAt: DateTime.utc(2026, 7, 13, 8),
  expiresAt: DateTime.utc(2026, 8, 3, 8),
  current: false,
);

final _ipv6PortLabelSession = DeviceSession(
  id: 'ipv6-port',
  deviceLabel: 'Scanner [2001:db8::1]:443 primary',
  platform: 'windows',
  userAgentFamily: 'Chrome',
  createdAt: DateTime.utc(2026, 7, 3, 8),
  lastUsedAt: DateTime.utc(2026, 7, 13, 8),
  expiresAt: DateTime.utc(2026, 8, 3, 8),
  current: false,
);

final class _FakeAuthRepository
    implements AuthRepository, AuthCredentialInvalidator {
  _FakeAuthRepository({required this.sessions, this.holdRevokeOthers = false});

  final List<DeviceSession> sessions;
  final bool holdRevokeOthers;
  Failure? listFailure;
  final List<String> revokeSessionCalls = [];
  int revokeOthersCalls = 0;
  int revokeAllCalls = 0;
  int expireCredentialCalls = 0;
  int listCalls = 0;
  final _revokeOthersCompleter = ValueNotifier<bool>(false);

  void releaseRevokeOthers() => _revokeOthersCompleter.value = true;

  @override
  Future<Result<List<DeviceSession>>> listDeviceSessions() async {
    listCalls += 1;
    final failure = listFailure;
    return failure == null
        ? Success(List.of(sessions))
        : FailureResult(failure);
  }

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) async {
    revokeSessionCalls.add(sessionId);
    return const Success(null);
  }

  @override
  Future<Result<int>> revokeOtherDeviceSessions() async {
    revokeOthersCalls += 1;
    if (holdRevokeOthers) {
      while (!_revokeOthersCompleter.value) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    return const Success(1);
  }

  @override
  Future<Result<int>> revokeAllDeviceSessions() async {
    revokeAllCalls += 1;
    return Success(sessions.length);
  }

  @override
  Future<void> expireCredentials() async => expireCredentialCalls += 1;

  @override
  Future<Result<AuthSession?>> restoreSession() async => const Success(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async => const FailureResult(AuthenticationFailure());

  @override
  Future<void> logout() async {}
}

final class _RecordingOwnershipCoordinator
    implements OfflineOwnershipCoordinator {
  final List<OfflineOwnershipReason> reasons = [];

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) async {
    reasons.add(intent.reason);
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
