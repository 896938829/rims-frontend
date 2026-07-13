import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/home/presentation/pages/home_page.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_document_draft_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/presentation/widgets/offline_status_bar.dart';
import 'package:rims_frontend/features/reports/domain/entities/report_data.dart';
import 'package:rims_frontend/features/reports/domain/repositories/reports_repository.dart';
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

  testWidgets('login page shows restoring session state', (tester) async {
    final restoreCompleter = Completer<Result<AuthSession?>>();
    final sessionController = AuthSessionController();
    unawaited(
      sessionController.restoreSession(
        _FakeAuthRepository(restoreFuture: restoreCompleter.future),
      ),
    );

    await _pumpApp(tester, sessionController: sessionController);

    expect(find.text('正在恢复登录状态...'), findsOneWidget);
    final loginButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '登录'),
    );
    expect(loginButton.onPressed, isNull);

    restoreCompleter.complete(const Success<AuthSession?>(null));
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
    expect(find.text('你好，系统管理员'), findsOneWidget);
    expect(find.text('库存预警'), findsOneWidget);
  });

  testWidgets(
    'login page explains account provisioning and hides registration',
    (tester) async {
      await _pumpApp(tester);

      expect(find.text('账号由管理员创建，请使用分配的账号登录'), findsOneWidget);
      expect(find.byKey(const Key('show-register-button')), findsNothing);
      expect(find.text('没有账号？注册'), findsNothing);
      expect(find.text('注册并登录'), findsNothing);
      expect(find.byKey(const Key('register-username-field')), findsNothing);
    },
  );

  testWidgets('shell bottom navigation switches tab body', (tester) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-inventory')), findsOneWidget);
  });

  testWidgets(
    'shell shows API unreachable band without covering home content',
    (tester) async {
      final sessionController = AuthSessionController()..startSession(_session);
      await _pumpApp(
        tester,
        initialLocation: RoutePaths.shell,
        sessionController: sessionController,
        networkStatusService: const _FakeNetworkStatusService(
          NetworkReachability.unreachable,
        ),
      );

      expect(find.text('网络可用，服务不可达'), findsOneWidget);
      expect(find.text('你好，系统管理员'), findsOneWidget);
      expect(find.text('在线，服务可用'), findsNothing);
    },
  );

  testWidgets('shell refreshes status counts after Sync Center returns', (
    tester,
  ) async {
    final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    await outbox.enqueue(_statusOperation('first'));
    final sessionController = AuthSessionController()
      ..startSession(_statusSession);
    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      networkStatusService: const _FakeNetworkStatusService(
        NetworkReachability.online,
      ),
      outboxRepository: outbox,
    );
    await tester.pumpAndSettle();

    expect(find.text('待同步 1'), findsOneWidget);
    await tester.tap(find.text('待同步 1'));
    await tester.pumpAndSettle();
    expect(find.text('同步服务不可用'), findsOneWidget);

    await outbox.enqueue(_statusOperation('second'));
    Navigator.of(tester.element(find.text('同步服务不可用'))).pop();
    await tester.pumpAndSettle();

    expect(find.text('待同步 2'), findsOneWidget);
  });

  testWidgets('shell keeps the status band below the top SafeArea', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final sessionController = AuthSessionController()..startSession(_session);

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      networkStatusService: const _FakeNetworkStatusService(
        NetworkReachability.unreachable,
      ),
    );
    await tester.pumpAndSettle();

    final bandTop = tester.getTopLeft(find.byType(OfflineStatusBar)).dy;
    expect(bandTop, 24);
    expect(find.text('你好，系统管理员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile warehouse selector switches active warehouse', (
    tester,
  ) async {
    final sessionController = AuthSessionController()
      ..startSession(_multiWarehouseSession);
    final repository = _FakeAuthRepository(
      switchWarehouseResult: const Success<Warehouse>(_beijingWarehouse),
    );
    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      authRepository: repository,
    );

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-warehouse-selector')), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-warehouse-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('北京仓').last);
    await tester.pumpAndSettle();

    expect(sessionController.currentWarehouse?.id, 2);
    expect(find.text('北京仓'), findsWidgets);
    expect(repository.lastSwitchWarehouseId, 2);
  });

  testWidgets(
    'warehouse switch replaces Home scope before stale completion can report',
    (tester) async {
      final sessionController = AuthSessionController()
        ..startSession(_multiWarehouseSession);
      await _pumpApp(
        tester,
        initialLocation: RoutePaths.shell,
        sessionController: sessionController,
        networkStatusService: const _FakeNetworkStatusService(
          NetworkReachability.online,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('home-1-1')), findsOneWidget);

      await sessionController.startSession(_beijingSession);
      await tester.pump();

      expect(find.byKey(const Key('home-1-1')), findsNothing);
      expect(find.byKey(const Key('home-1-2')), findsOneWidget);
      expect(find.byType(HomePage), findsOneWidget);
    },
  );

  testWidgets('profile warehouse switch restores refreshed session context', (
    tester,
  ) async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final sessionController = AuthSessionController()
      ..startSession(_multiWarehouseSession);
    final repository = _FakeAuthRepository(
      restoreFuture: Future.value(const Success<AuthSession?>(_beijingSession)),
      switchWarehouseResult: const Success<Warehouse>(_beijingWarehouse),
    );
    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      authRepository: repository,
      eventBus: eventBus,
    );

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-warehouse-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('北京仓').last);
    await tester.pumpAndSettle();

    expect(repository.lastSwitchWarehouseId, 2);
    expect(repository.restoreCallCount, 1);
    expect(sessionController.currentWarehouse?.id, 2);
  });

  testWidgets(
    'profile warehouse switch keeps selection when refresh lacks current marker',
    (tester) async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      final sessionController = AuthSessionController()
        ..startSession(_multiWarehouseSession);
      final repository = _FakeAuthRepository(
        restoreFuture: Future.value(
          const Success<AuthSession?>(_multiWarehouseSession),
        ),
        switchWarehouseResult: const Success<Warehouse>(_beijingWarehouse),
      );
      await _pumpApp(
        tester,
        initialLocation: RoutePaths.shell,
        sessionController: sessionController,
        authRepository: repository,
        eventBus: eventBus,
      );

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-warehouse-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('北京仓').last);
      await tester.pumpAndSettle();

      expect(repository.lastSwitchWarehouseId, 2);
      expect(repository.restoreCallCount, 1);
      expect(sessionController.currentWarehouse?.id, 2);
      expect(find.text('北京仓'), findsWidgets);
    },
  );

  test('home scan sale action requests scanner on document navigation', () {
    final action = HomeViewModel().quickActions.firstWhere(
      (item) => item.label == '扫码销售',
    );

    expect(action.documentActionLabel, '销售出库');
    expect(action.requestsScanner, isTrue);
  });

  testWidgets('home quick action opens matching document workflow', (
    tester,
  ) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.ensureVisible(find.text('入库'));
    await tester.tap(find.text('入库'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-documents')), findsOneWidget);
    expect(find.text('新建 采购入库'), findsOneWidget);
  });

  testWidgets('home return action opens return document workflow', (
    tester,
  ) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.ensureVisible(find.text('退货'));
    await tester.tap(find.text('退货'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-documents')), findsOneWidget);
    expect(find.text('新建 退货入库'), findsOneWidget);
  });

  testWidgets('home stocktake action opens stocktake document workflow', (
    tester,
  ) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.ensureVisible(find.text('盘点'));
    await tester.tap(find.text('盘点'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-documents')), findsOneWidget);
    expect(find.text('新建 盘点单'), findsOneWidget);
  });

  testWidgets('documents tab hides admin-only workflows for operator', (
    tester,
  ) async {
    final sessionController = AuthSessionController()
      ..startSession(_userSession);
    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
    );

    await tester.tap(find.text('单据'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-documents')), findsOneWidget);
    expect(find.text('销售出库'), findsOneWidget);
    expect(find.text('采购入库'), findsOneWidget);
    expect(find.text('退货入库'), findsOneWidget);
    expect(find.text('盘点单'), findsOneWidget);
    expect(find.text('调拨单'), findsNothing);
    expect(find.text('转标准'), findsNothing);
  });

  testWidgets('unauthenticated shell route redirects to login', (tester) async {
    await _pumpApp(tester, initialLocation: RoutePaths.shell);

    expect(find.text('登录'), findsWidgets);
  });

  testWidgets(
    'shell route redirects to login after restore completes without session',
    (tester) async {
      final restoreCompleter = Completer<Result<AuthSession?>>();
      final sessionController = AuthSessionController();
      unawaited(
        sessionController.restoreSession(
          _FakeAuthRepository(restoreFuture: restoreCompleter.future),
        ),
      );

      await _pumpApp(
        tester,
        initialLocation: RoutePaths.shell,
        sessionController: sessionController,
      );

      restoreCompleter.complete(const Success<AuthSession?>(null));
      await tester.pumpAndSettle();

      expect(find.text('登录'), findsWidgets);
      expect(find.byKey(const Key('tab-body-home')), findsNothing);
    },
  );

  testWidgets('shell route shows login restore state while restoring session', (
    tester,
  ) async {
    final restoreCompleter = Completer<Result<AuthSession?>>();
    final sessionController = AuthSessionController();
    unawaited(
      sessionController.restoreSession(
        _FakeAuthRepository(restoreFuture: restoreCompleter.future),
      ),
    );

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
    );

    expect(find.text('登录'), findsWidgets);
    expect(find.text('正在恢复登录状态...'), findsOneWidget);
    expect(find.text('你好，未登录用户'), findsNothing);

    restoreCompleter.complete(const Success<AuthSession?>(null));
  });

  testWidgets('profile logout returns to login page', (tester) async {
    await _pumpApp(tester);

    await _login(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await _scrollToProfileLogout(tester);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-logout-delete-drafts')));
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsWidgets);
  });

  testWidgets('profile logout clears persisted auth session', (tester) async {
    final authRepository = _FakeAuthRepository();
    await _pumpApp(tester, authRepository: authRepository);

    await _login(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await _scrollToProfileLogout(tester);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-logout-delete-drafts')));
    await tester.pumpAndSettle();

    expect(authRepository.logoutCallCount, 1);
  });

  testWidgets('expired session redirects to login with visible message', (
    tester,
  ) async {
    final sessionController = AuthSessionController()..startSession(_session);
    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
    );

    sessionController.expireSession();
    await tester.pumpAndSettle();

    expect(find.text('登录'), findsWidgets);
    expect(find.text('登录已过期，请重新登录'), findsOneWidget);
  });

  testWidgets('shell restores session when global refresh is requested', (
    tester,
  ) async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final sessionController = AuthSessionController()..startSession(_session);
    final authRepository = _FakeAuthRepository(
      restoreFuture: Future.value(const Success<AuthSession?>(_session)),
    );

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      authRepository: authRepository,
      eventBus: eventBus,
    );

    eventBus.publish(const GlobalRefreshRequestedEvent());
    await tester.pump();
    await tester.pump();

    expect(authRepository.restoreCallCount, 1);
    expect(sessionController.currentUser?.username, 'admin');
  });

  testWidgets('shell keeps session when global refresh fails', (tester) async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final sessionController = AuthSessionController()..startSession(_session);
    final authRepository = _FakeAuthRepository(
      restoreFuture: Future.value(
        const FailureResult<AuthSession?>(NetworkFailure(message: '刷新失败')),
      ),
    );

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      authRepository: authRepository,
      eventBus: eventBus,
    );

    eventBus.publish(const GlobalRefreshRequestedEvent());
    await tester.pump();
    await tester.pump();

    expect(authRepository.restoreCallCount, 1);
    expect(sessionController.currentUser?.username, 'admin');
    expect(find.text('首页'), findsWidgets);
    expect(find.text('登录'), findsNothing);
  });

  testWidgets('shell redirects to login when global refresh is unauthorized', (
    tester,
  ) async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final sessionController = AuthSessionController()..startSession(_session);
    final authRepository = _FakeAuthRepository(
      restoreFuture: Future.value(
        const FailureResult<AuthSession?>(
          AuthenticationFailure(message: '登录已过期', businessCode: 10001),
        ),
      ),
    );

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      authRepository: authRepository,
      eventBus: eventBus,
    );

    eventBus.publish(const GlobalRefreshRequestedEvent());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(authRepository.restoreCallCount, 1);
    expect(sessionController.isAuthenticated, isFalse);
    expect(find.text('登录'), findsWidgets);
    expect(find.text('登录已过期'), findsOneWidget);
  });

  testWidgets('regular user reports hide financial metrics', (tester) async {
    final sessionController = AuthSessionController()
      ..startSession(_userSession);

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      reportsRepository: _FakeReportsRepository(),
    );

    await tester.tap(find.text('报表'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-reports')), findsOneWidget);
    expect(find.text('销售额'), findsNothing);
    expect(find.text('销售趋势（元）'), findsNothing);
    expect(find.text('商品排行（销售额）'), findsNothing);
    expect(find.text('订单数'), findsNothing);
    expect(find.text('销量'), findsNothing);
    expect(find.text('库存概览'), findsOneWidget);
  });

  testWidgets('uppercase admin role can view financial metrics', (
    tester,
  ) async {
    final sessionController = AuthSessionController()
      ..startSession(_upperCaseAdminSession);

    await _pumpApp(
      tester,
      initialLocation: RoutePaths.shell,
      sessionController: sessionController,
      reportsRepository: _FakeReportsRepository(),
    );

    await tester.tap(find.text('报表'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-body-reports')), findsOneWidget);
    expect(find.text('销售额'), findsOneWidget);
    expect(find.text('销售趋势（元）'), findsOneWidget);
    expect(find.text('商品排行（销售额）'), findsOneWidget);
  });

  testWidgets(
    'draft route follows authenticated account switches without stale rows',
    (tester) async {
      final store = MemoryOfflineStore();
      final drafts = DriftDocumentDraftRepository(store: store);
      await drafts.save(
        _routeDraft('account-1', accountId: '1', docType: 1),
        expectedVersion: 0,
      );
      await drafts.save(
        _routeDraft('account-2', accountId: '2', docType: 2),
        expectedVersion: 0,
      );
      final sessionController = AuthSessionController()..startSession(_session);

      await _pumpApp(
        tester,
        initialLocation: RoutePaths.drafts,
        sessionController: sessionController,
        documentDraftRepository: drafts,
      );
      await tester.pumpAndSettle();
      expect(find.text('草稿管理'), findsOneWidget);
      expect(find.text('采购入库'), findsOneWidget);
      expect(find.text('销售出库'), findsNothing);

      sessionController.startSession(_secondAccountSession);
      await tester.pumpAndSettle();

      expect(find.text('采购入库'), findsNothing);
      expect(find.text('销售出库'), findsOneWidget);
    },
  );
}

Future<void> _scrollToProfileLogout(WidgetTester tester) async {
  for (
    var index = 0;
    index < 20 && find.text('退出登录').evaluate().isEmpty;
    index += 1
  ) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  expect(find.text('退出登录'), findsOneWidget);
}

Future<void> _pumpApp(
  WidgetTester tester, {
  String initialLocation = RoutePaths.login,
  AuthSessionController? sessionController,
  AuthRepository? authRepository,
  AppEventBus? eventBus,
  ReportsRepository? reportsRepository,
  DocumentDraftRepository? documentDraftRepository,
  NetworkStatusService? networkStatusService,
  OutboxRepository? outboxRepository,
}) async {
  final activeSessionController = sessionController ?? AuthSessionController();

  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: createAppRouter(
        authRepository: authRepository ?? _FakeAuthRepository(),
        sessionController: activeSessionController,
        eventBus: eventBus,
        reportsRepository: reportsRepository,
        documentDraftRepository: documentDraftRepository,
        networkStatusService: networkStatusService,
        outboxRepository: outboxRepository,
        initialLocation: initialLocation,
      ),
    ),
  );
  await tester.pump();
}

final class _FakeNetworkStatusService implements NetworkStatusService {
  const _FakeNetworkStatusService(this.current);

  @override
  final NetworkReachability current;

  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  Future<NetworkReachability> verify() async => current;

  @override
  void markOnlineFromRequest() {}

  @override
  Future<void> dispose() async {}
}

DocumentDraft _routeDraft(
  String id, {
  required String accountId,
  required int docType,
}) {
  final timestamp = DateTime.utc(2026, 7, 13);
  return DocumentDraft(
    id: id,
    accountId: accountId,
    warehouseId: 1,
    docType: docType,
    observedRoleCode: 'admin',
    payload: const {'lines': <Object?>[], 'remark': ''},
    createdAt: timestamp,
    updatedAt: timestamp,
  );
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

const _statusSession = AuthSession(
  accessToken: 'token-status',
  user: AppUser(
    id: 7,
    username: 'status-user',
    realName: '状态用户',
    roleCode: 'operator',
    roleName: '操作员',
    permissionCodes: {'document:create'},
  ),
  currentWarehouse: Warehouse(
    id: 11,
    code: 'MAIN',
    name: 'Main',
    isDefault: true,
  ),
  warehouses: [Warehouse(id: 11, code: 'MAIN', name: 'Main', isDefault: true)],
);

OutboxOperation _statusOperation(String id) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'status-$id',
    accountId: '7',
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: const {},
    state: OutboxState.queued,
    createdAt: DateTime.utc(2026, 7, 14),
  );
}

const _secondAccountSession = AuthSession(
  accessToken: 'token-2',
  user: AppUser(
    id: 2,
    username: 'second',
    realName: '第二账号',
    roleCode: 'admin',
    roleName: '管理员',
  ),
  currentWarehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
  warehouses: [Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true)],
);

const _beijingWarehouse = Warehouse(
  id: 2,
  code: 'BJ',
  name: '北京仓',
  isDefault: false,
);

const _multiWarehouseSession = AuthSession(
  accessToken: 'token-123',
  user: AppUser(
    id: 1,
    username: 'admin',
    realName: '系统管理员',
    roleCode: 'admin',
    roleName: '管理员',
  ),
  currentWarehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
  warehouses: [
    Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
    _beijingWarehouse,
  ],
);

const _beijingSession = AuthSession(
  accessToken: 'token-123',
  user: AppUser(
    id: 1,
    username: 'admin',
    realName: '系统管理员',
    roleCode: 'admin',
    roleName: '管理员',
  ),
  currentWarehouse: _beijingWarehouse,
  warehouses: [
    Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: false),
    _beijingWarehouse,
  ],
);

const _userSession = AuthSession(
  accessToken: 'token-user',
  user: AppUser(
    id: 2,
    username: 'operator',
    realName: '操作员',
    roleCode: 'user',
    roleName: '普通用户',
  ),
  currentWarehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
  warehouses: [Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true)],
);

const _upperCaseAdminSession = AuthSession(
  accessToken: 'token-admin-uppercase',
  user: AppUser(
    id: 3,
    username: 'admin_upper',
    realName: '大写管理员',
    roleCode: 'ADMIN',
    roleName: '管理员',
  ),
  currentWarehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
  warehouses: [Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true)],
);

final class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({
    this.restoreFuture,
    this.switchWarehouseResult = const FailureResult<Warehouse>(
      UnknownFailure(),
    ),
  });

  final Future<Result<AuthSession?>>? restoreFuture;
  final Result<Warehouse> switchWarehouseResult;
  int? lastSwitchWarehouseId;
  int restoreCallCount = 0;
  int logoutCallCount = 0;

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    restoreCallCount += 1;
    return restoreFuture ?? const Success<AuthSession?>(null);
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    lastSwitchWarehouseId = warehouse.id;
    return switchWarehouseResult;
  }

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
  Future<void> logout() async {
    logoutCallCount += 1;
  }
}

final class _FakeReportsRepository implements ReportsRepository {
  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<SalesStats>(
      SalesStats(revenue: 12345, orderCount: 8, skuCount: 3, quantity: 32),
    );
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<List<SalesTrendPoint>>([
      SalesTrendPoint(date: '2026-06-26', amount: 230),
    ]);
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    return const Success<List<SalesRankingItem>>([
      SalesRankingItem(productName: '真实商品', amount: 12345),
    ]);
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    return const Success<List<InventoryOverviewItem>>([
      InventoryOverviewItem(label: '正常库存', value: 80),
    ]);
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    return const Success<List<InventoryTurnoverItem>>([
      InventoryTurnoverItem(
        productName: '矿泉水',
        sku: 'SKU-WA',
        soldQuantity: 20,
        averageStockQuantity: 10,
        turnoverRate: 2.5,
      ),
    ]);
  }

  @override
  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    return Success(
      PageData(
        items: const [
          SlowMovingInventoryItem(
            productName: '纸巾',
            sku: 'SKU-TI',
            stockQuantity: 80,
            salesQuantity: 0,
            lastSaleAt: null,
          ),
        ],
        total: 1,
        page: page,
        pageSize: pageSize,
      ),
    );
  }
}
