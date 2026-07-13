import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/theme/app_theme.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/offline_status_view_model.dart';
import 'package:rims_frontend/features/offline/presentation/widgets/offline_status_bar.dart';

void main() {
  const stateLabels = {
    NetworkReachability.checking: '正在检查服务',
    NetworkReachability.offline: '离线，无网络连接',
    NetworkReachability.unreachable: '网络可用，服务不可达',
    NetworkReachability.online: '在线，服务可用',
  };

  for (final entry in stateLabels.entries) {
    testWidgets('shows ${entry.key.name} without conflating reachability', (
      tester,
    ) async {
      final harness = await _createHarness(reachability: entry.key);
      addTearDown(harness.dispose);

      await _pumpBar(tester, harness.viewModel);

      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows stale cache age separately from network state', (
    tester,
  ) async {
    final harness = await _createHarness(
      reachability: NetworkReachability.unreachable,
      now: DateTime.utc(2026, 7, 14, 12),
    );
    addTearDown(harness.dispose);
    harness.viewModel.updateDataFreshness(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'test',
      fetchedAt: DateTime.utc(2026, 7, 14, 9),
      expiresAt: DateTime.utc(2026, 7, 14, 10),
    );

    await _pumpBar(tester, harness.viewModel);

    expect(find.text('网络可用，服务不可达'), findsOneWidget);
    expect(find.text('陈旧缓存 · 3 小时前'), findsOneWidget);
  });

  test('notifies at age and expiry boundaries without real waiting', () async {
    final clock = _FakeClock(DateTime.utc(2026, 7, 14, 12));
    final scheduler = _FakeTimerScheduler(clock);
    final network = _FakeNetworkStatusService(NetworkReachability.online);
    final viewModel = OfflineStatusViewModel(
      networkStatusService: network,
      outboxRepository: null,
      contextReader: () => _context(),
      now: clock.now,
      scheduleTimer: scheduler.schedule,
    );
    var notifications = 0;
    viewModel.addListener(() => notifications += 1);
    viewModel.updateDataFreshness(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'test',
      fetchedAt: DateTime.utc(2026, 7, 14, 11, 59, 30),
      expiresAt: DateTime.utc(2026, 7, 14, 12, 0, 45),
      hasCachedData: true,
    );

    expect(viewModel.isStale, isFalse);
    expect(viewModel.dataAgeLabel, '缓存数据 · 刚刚更新');
    scheduler.advance(const Duration(seconds: 30));
    expect(viewModel.dataAgeLabel, '缓存数据 · 1 分钟前');
    expect(notifications, 2);

    scheduler.advance(const Duration(seconds: 15));
    expect(viewModel.isStale, isTrue);
    expect(viewModel.dataAgeLabel, '陈旧缓存 · 1 分钟前');
    expect(notifications, 3);

    viewModel.dispose();
    expect(scheduler.activeTimerCount, 0);
    await network.dispose();
  });

  testWidgets('online fresh cache stays transparent without claiming stale', (
    tester,
  ) async {
    final harness = await _createHarness(
      reachability: NetworkReachability.online,
      now: DateTime.utc(2026, 7, 14, 12),
    );
    addTearDown(harness.dispose);
    harness.viewModel.updateDataFreshness(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'test',
      fetchedAt: DateTime.utc(2026, 7, 14, 11, 59, 30),
      expiresAt: DateTime.utc(2026, 7, 14, 12, 5),
      hasCachedData: true,
    );

    await _pumpBar(tester, harness.viewModel);

    expect(harness.viewModel.isStale, isFalse);
    expect(find.text('在线，服务可用'), findsOneWidget);
    expect(find.text('缓存数据 · 刚刚更新'), findsOneWidget);
    expect(find.textContaining('陈旧缓存'), findsNothing);
  });

  test('warehouse switch immediately clears prior freshness', () async {
    final clock = _FakeClock(DateTime.utc(2026, 7, 14, 12));
    final scheduler = _FakeTimerScheduler(clock);
    final network = _FakeNetworkStatusService(NetworkReachability.online);
    var context = _context(warehouseId: 11);
    final viewModel = OfflineStatusViewModel(
      networkStatusService: network,
      outboxRepository: null,
      contextReader: () => context,
      now: clock.now,
      scheduleTimer: scheduler.schedule,
    );
    viewModel.updateDataFreshness(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'test',
      fetchedAt: DateTime.utc(2026, 7, 14, 9),
      expiresAt: DateTime.utc(2026, 7, 14, 10),
      hasCachedData: true,
    );
    expect(viewModel.dataAgeLabel, '陈旧缓存 · 3 小时前');

    context = _context(warehouseId: 12);
    viewModel.refreshContext();

    expect(viewModel.dataAgeLabel, '数据时间未知');
    expect(scheduler.activeTimerCount, 0);
    viewModel.dispose();
    await network.dispose();
  });

  test('late freshness completion from prior warehouse is ignored', () async {
    final clock = _FakeClock(DateTime.utc(2026, 7, 14, 12));
    final scheduler = _FakeTimerScheduler(clock);
    final network = _FakeNetworkStatusService(NetworkReachability.online);
    var context = _context(warehouseId: 11);
    final viewModel = OfflineStatusViewModel(
      networkStatusService: network,
      outboxRepository: null,
      contextReader: () => context,
      now: clock.now,
      scheduleTimer: scheduler.schedule,
    );
    final staleCompletion = Completer<void>();
    final lateReport = staleCompletion.future.then((_) {
      viewModel.updateDataFreshness(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'test',
        fetchedAt: DateTime.utc(2026, 7, 14, 8),
        expiresAt: DateTime.utc(2026, 7, 14, 9),
        hasCachedData: true,
      );
    });

    context = _context(warehouseId: 12);
    viewModel.refreshContext();
    staleCompletion.complete();
    await lateReport;

    expect(viewModel.dataAgeLabel, '数据时间未知');
    expect(scheduler.activeTimerCount, 0);
    viewModel.dispose();
    await network.dispose();
  });

  test(
    'permission stamp change clears freshness and rejects late reports',
    () async {
      final network = _FakeNetworkStatusService(NetworkReachability.online);
      var context = _context(permissionStamp: 'full');
      final viewModel = OfflineStatusViewModel(
        networkStatusService: network,
        outboxRepository: null,
        contextReader: () => context,
      );
      viewModel.updateDataFreshness(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'full',
        fetchedAt: DateTime.utc(2026, 7, 14, 8),
        expiresAt: DateTime.utc(2026, 7, 14, 9),
        hasCachedData: true,
      );

      context = _context(permissionStamp: 'limited');
      viewModel.refreshContext();
      viewModel.updateDataFreshness(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'full',
        fetchedAt: DateTime.utc(2026, 7, 14, 7),
        expiresAt: DateTime.utc(2026, 7, 14, 8),
        hasCachedData: true,
      );

      expect(viewModel.dataAgeLabel, '数据时间未知');
      viewModel.dispose();
      await network.dispose();
    },
  );

  test(
    'permission changes clear counts and list failure keeps them cleared',
    () async {
      final network = _FakeNetworkStatusService(NetworkReachability.online);
      final delegate = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      await delegate.enqueue(
        _operation(
          'permission-sensitive',
          OutboxState.queued,
          kind: OutboxOperationKind.documentComplete,
        ),
      );
      final repository = _CountingOutboxRepository(delegate);
      var context = _context(permissionStamp: 'full');
      final viewModel = OfflineStatusViewModel(
        networkStatusService: network,
        outboxRepository: repository,
        contextReader: () => context,
      );
      await viewModel.load();
      expect(viewModel.queuedCount, 1);

      context = _context(
        permissionStamp: 'limited',
        allowedKinds: const {OutboxOperationKind.documentCreate},
      );
      viewModel.refreshContext();
      expect((viewModel.queuedCount, viewModel.attentionCount), (0, 0));
      await viewModel.load();
      expect((viewModel.queuedCount, viewModel.attentionCount), (0, 1));

      repository.listFailure = const LocalStorageFailure(
        message: 'read failed',
      );
      context = _context(permissionStamp: 'restored');
      viewModel.refreshContext();
      await viewModel.load();
      expect((viewModel.queuedCount, viewModel.attentionCount), (0, 0));

      repository.listFailure = null;
      context = _context(permissionStamp: 'full-again');
      viewModel.refreshContext();
      await viewModel.load();
      expect((viewModel.queuedCount, viewModel.attentionCount), (1, 0));

      viewModel.dispose();
      await network.dispose();
    },
  );

  test('status graph lookup is skipped when no permission is denied', () async {
    final network = _FakeNetworkStatusService(NetworkReachability.online);
    final delegate = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    await delegate.enqueue(_operation('allowed', OutboxState.queued));
    final repository = _CountingOutboxRepository(delegate);
    final viewModel = OfflineStatusViewModel(
      networkStatusService: network,
      outboxRepository: repository,
      contextReader: _context,
    );

    await viewModel.load();

    expect(repository.connectedComponentCalls, 0);
    viewModel.dispose();
    await network.dispose();
  });

  test('500 denied operations use one connected graph lookup', () async {
    final network = _FakeNetworkStatusService(NetworkReachability.online);
    final delegate = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    for (var index = 0; index < 500; index += 1) {
      await delegate.enqueue(
        _operation(
          'denied-$index',
          OutboxState.queued,
          kind: OutboxOperationKind.documentComplete,
        ),
      );
    }
    final repository = _CountingOutboxRepository(delegate);
    final viewModel = OfflineStatusViewModel(
      networkStatusService: network,
      outboxRepository: repository,
      contextReader: () =>
          _context(allowedKinds: const {OutboxOperationKind.documentCreate}),
    );

    await viewModel.load();

    expect(repository.connectedComponentCalls, 1);
    expect(viewModel.attentionCount, 500);
    viewModel.dispose();
    await network.dispose();
  });

  testWidgets('shows queued and conflict counts and opens Sync Center', (
    tester,
  ) async {
    final harness = await _createHarness(
      operations: [
        _operation('queued', OutboxState.queued),
        _operation('retry', OutboxState.retryableFailure),
        _operation('conflict', OutboxState.conflict),
      ],
    );
    addTearDown(harness.dispose);
    var openCount = 0;

    await _pumpBar(
      tester,
      harness.viewModel,
      onOpenSyncCenter: () => openCount += 1,
    );

    expect(find.text('待同步 2'), findsOneWidget);
    expect(find.text('需处理 1'), findsOneWidget);
    await tester.tap(find.text('待同步 2'));
    await tester.tap(find.text('需处理 1'));
    expect(openCount, 2);
  });

  testWidgets(
    'scopes counts to warehouse and classifies permission blocks as attention',
    (tester) async {
      final harness = await _createHarness(
        operations: [
          _operation('allowed', OutboxState.queued),
          _operation('other-warehouse', OutboxState.queued, warehouseId: 12),
          _operation(
            'permission-blocked',
            OutboxState.queued,
            kind: OutboxOperationKind.documentComplete,
          ),
        ],
        allowedKinds: const {OutboxOperationKind.documentCreate},
      );
      addTearDown(harness.dispose);

      await _pumpBar(tester, harness.viewModel);

      expect(find.text('待同步 1'), findsOneWidget);
      expect(find.text('需处理 1'), findsOneWidget);
    },
  );

  testWidgets('supports keyboard activation and descriptive semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = await _createHarness(
      operations: [_operation('queued', OutboxState.queued)],
    );
    addTearDown(harness.dispose);
    var openCount = 0;

    await _pumpBar(
      tester,
      harness.viewModel,
      onOpenSyncCenter: () => openCount += 1,
    );

    expect(find.bySemanticsLabel('在线，服务可用'), findsOneWidget);
    expect(find.bySemanticsLabel('数据时间未知'), findsOneWidget);
    expect(find.bySemanticsLabel('1 项待同步，打开同步中心'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(openCount, 1);
    semantics.dispose();
  });

  testWidgets(
    'status labels occur once and count controls keep separate actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = await _createHarness(
        operations: [_operation('queued', OutboxState.queued)],
      );
      addTearDown(harness.dispose);
      await _pumpBar(tester, harness.viewModel, onOpenSyncCenter: () {});

      expect(find.bySemanticsLabel('在线，服务可用'), findsOneWidget);
      expect(find.bySemanticsLabel('数据时间未知'), findsOneWidget);
      expect(find.bySemanticsLabel('1 项待同步，打开同步中心'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('在线，服务可用.*在线，服务可用')), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('count controls provide 48 logical pixel touch targets', (
    tester,
  ) async {
    final harness = await _createHarness(
      operations: [
        _operation('queued', OutboxState.queued),
        _operation('conflict', OutboxState.conflict),
      ],
    );
    addTearDown(harness.dispose);
    await _pumpBar(tester, harness.viewModel, onOpenSyncCenter: () {});

    for (final label in ['待同步 1', '需处理 1']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextButton),
      );
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(
        tester.hitTestOnBinding(tester.getCenter(button)).path,
        isNotEmpty,
      );
    }
  });

  for (final size in const [Size(320, 640), Size(1024, 768)]) {
    testWidgets('does not overflow at ${size.width.toInt()} px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await _createHarness(
        reachability: NetworkReachability.unreachable,
        operations: [
          _operation('queued', OutboxState.queued),
          _operation('conflict', OutboxState.conflict),
        ],
      );
      addTearDown(harness.dispose);

      await _pumpBar(tester, harness.viewModel);

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(OfflineStatusBar)).width, size.width);
    });
  }

  for (final mode in ThemeMode.values.where(
    (mode) => mode != ThemeMode.system,
  )) {
    testWidgets('supports ${mode.name} theme and text scale 2.0', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await _createHarness(
        reachability: NetworkReachability.offline,
        operations: [_operation('conflict', OutboxState.conflict)],
      );
      addTearDown(harness.dispose);

      await _pumpBar(
        tester,
        harness.viewModel,
        themeMode: mode,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('离线，无网络连接'), findsOneWidget);
    });
  }
}

Future<_Harness> _createHarness({
  NetworkReachability reachability = NetworkReachability.online,
  List<OutboxOperation> operations = const [],
  DateTime? now,
  Set<OutboxOperationKind> allowedKinds = const {...OutboxOperationKind.values},
}) async {
  final network = _FakeNetworkStatusService(reachability);
  final clock = _FakeClock(now ?? DateTime.now());
  final scheduler = _FakeTimerScheduler(clock);
  final repository = MemoryOutboxRepository(
    stateMachine: OutboxStateMachine(now: clock.now),
    now: clock.now,
  );
  for (final operation in operations) {
    await repository.enqueue(
      operation.state == OutboxState.queued
          ? operation
          : operation.copyWith(state: OutboxState.queued),
    );
    if (operation.state != OutboxState.queued) {
      await repository.transition(
        accountId: operation.accountId,
        operationId: operation.operationId,
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: operation.accountId,
        operationId: operation.operationId,
        next: operation.state,
      );
    }
  }
  final viewModel = OfflineStatusViewModel(
    networkStatusService: network,
    outboxRepository: repository,
    contextReader: () => _context(allowedKinds: allowedKinds),
    now: clock.now,
    scheduleTimer: scheduler.schedule,
  );
  await viewModel.load();
  return _Harness(network: network, viewModel: viewModel);
}

OutboxExecutionContext _context({
  int warehouseId = 11,
  String permissionStamp = 'test',
  Set<OutboxOperationKind> allowedKinds = const {...OutboxOperationKind.values},
}) {
  return OutboxExecutionContext(
    accountId: '7',
    warehouseId: warehouseId,
    permissionStamp: permissionStamp,
    allowedKinds: allowedKinds,
  );
}

final class _CountingOutboxRepository implements OutboxRepository {
  _CountingOutboxRepository(this.delegate);

  final OutboxRepository delegate;
  Failure? listFailure;
  int connectedComponentCalls = 0;

  @override
  Future<Result<List<OutboxOperation>>> list(String accountId) async =>
      listFailure == null
      ? delegate.list(accountId)
      : FailureResult(listFailure!);

  @override
  Future<Result<List<OutboxOperation>>> loadConnectedComponent({
    required String accountId,
    required Set<String> operationIds,
  }) {
    connectedComponentCalls += 1;
    return delegate.loadConnectedComponent(
      accountId: accountId,
      operationIds: operationIds,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply(delegate.noSuchMethod, [invocation]);
}

OutboxOperation _operation(
  String id,
  OutboxState state, {
  int warehouseId = 11,
  OutboxOperationKind kind = OutboxOperationKind.documentCreate,
}) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: warehouseId,
    kind: kind,
    payload: const {},
    state: state,
    createdAt: DateTime.utc(2026, 7, 14),
  );
}

Future<void> _pumpBar(
  WidgetTester tester,
  OfflineStatusViewModel viewModel, {
  VoidCallback? onOpenSyncCenter,
  ThemeMode themeMode = ThemeMode.light,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Scaffold(
          body: OfflineStatusBar(
            viewModel: viewModel,
            onOpenSyncCenter: onOpenSyncCenter,
          ),
        ),
      ),
    ),
  );
}

final class _Harness {
  const _Harness({required this.network, required this.viewModel});

  final _FakeNetworkStatusService network;
  final OfflineStatusViewModel viewModel;

  Future<void> dispose() async {
    viewModel.dispose();
    await network.dispose();
  }
}

final class _FakeNetworkStatusService implements NetworkStatusService {
  _FakeNetworkStatusService(this._current);

  final StreamController<NetworkReachability> _controller =
      StreamController<NetworkReachability>.broadcast();
  NetworkReachability _current;

  @override
  NetworkReachability get current => _current;

  @override
  Stream<NetworkReachability> get changes => _controller.stream;

  @override
  Future<NetworkReachability> verify() async => _current;

  @override
  void markOnlineFromRequest() {
    _current = NetworkReachability.online;
    _controller.add(_current);
  }

  @override
  Future<void> dispose() => _controller.close();
}

final class _FakeClock {
  _FakeClock(this.value);

  DateTime value;

  DateTime now() => value;
}

final class _FakeTimerScheduler {
  _FakeTimerScheduler(this.clock);

  final _FakeClock clock;
  final List<_FakeTimer> _timers = [];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  Timer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(dueAt: clock.value.add(delay), callback: callback);
    _timers.add(timer);
    return timer;
  }

  void advance(Duration duration) {
    clock.value = clock.value.add(duration);
    while (true) {
      final due =
          _timers
              .where(
                (timer) => timer.isActive && !timer.dueAt.isAfter(clock.value),
              )
              .toList()
            ..sort((left, right) => left.dueAt.compareTo(right.dueAt));
      if (due.isEmpty) return;
      due.first.fire();
    }
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer({required this.dueAt, required this.callback});

  final DateTime dueAt;
  final void Function() callback;
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;

  @override
  void cancel() => _isActive = false;

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    callback();
  }
}
