import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/theme/app_theme.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
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
      fetchedAt: DateTime.utc(2026, 7, 14, 9),
      expiresAt: DateTime.utc(2026, 7, 14, 10),
    );

    await _pumpBar(tester, harness.viewModel);

    expect(find.text('网络可用，服务不可达'), findsOneWidget);
    expect(find.text('陈旧缓存 · 3 小时前'), findsOneWidget);
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

    expect(find.bySemanticsLabel('网络状态：在线，服务可用。数据时间未知'), findsOneWidget);
    expect(find.bySemanticsLabel('1 项待同步，打开同步中心'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(openCount, 1);
    semantics.dispose();
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
}) async {
  final network = _FakeNetworkStatusService(reachability);
  final repository = MemoryOutboxRepository(
    stateMachine: OutboxStateMachine(now: () => now ?? DateTime.now()),
    now: () => now ?? DateTime.now(),
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
    accountIdReader: () => '7',
    now: () => now ?? DateTime.now(),
  );
  await viewModel.load();
  return _Harness(network: network, viewModel: viewModel);
}

OutboxOperation _operation(String id, OutboxState state) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: 1,
    kind: OutboxOperationKind.documentCreate,
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
