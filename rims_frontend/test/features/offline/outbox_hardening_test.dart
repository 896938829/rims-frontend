import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/sync_center_view_model.dart';

void main() {
  final initial = DateTime.utc(2026, 7, 13, 12);
  late DateTime now;
  late MemoryOutboxRepository repository;

  OutboxOperation operation(
    String id, {
    int warehouseId = 11,
    OutboxOperationKind kind = OutboxOperationKind.documentCreate,
  }) => OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: warehouseId,
    kind: kind,
    payload: const {},
    state: OutboxState.queued,
    createdAt: initial,
  );

  const context = OutboxExecutionContext(
    accountId: '7',
    warehouseId: 11,
    permissionStamp: 'document:create',
    allowedKinds: {OutboxOperationKind.documentCreate},
  );

  setUp(() {
    now = initial;
    repository = MemoryOutboxRepository(
      stateMachine: OutboxStateMachine(now: () => now),
      now: () => now,
    );
  });

  test('review stamp is persisted with CAS and filters readiness', () async {
    await repository.enqueue(operation('review'));
    final current = (await repository.list('7')).successData.single;

    final confirmed = await repository.confirm(
      accountId: '7',
      operationId: 'review',
      reviewStamp: context.reviewStamp,
      expectedUpdatedAt: current.updatedAt,
    );

    expect(confirmed.successData.reviewStamp, context.reviewStamp);
    expect(
      (await repository.ready(
        '7',
        reviewStamp: context.reviewStamp,
      )).successData,
      hasLength(1),
    );
    expect(
      (await repository.ready('7', reviewStamp: 'changed')).successData,
      isEmpty,
    );
    expect(
      await repository.confirm(
        accountId: '7',
        operationId: 'review',
        reviewStamp: 'changed',
        expectedUpdatedAt: current.updatedAt,
      ),
      isA<FailureResult<OutboxOperation>>(),
    );
  });

  test(
    'stale syncing recovers as unknown and must remain probe-first',
    () async {
      await repository.enqueue(operation('stale'));
      await repository.transition(
        accountId: '7',
        operationId: 'stale',
        next: OutboxState.syncing,
      );
      now = initial.add(const Duration(minutes: 6));

      final recovered = await repository.recoverStaleSyncing(
        accountId: '7',
        staleBefore: now.subtract(const Duration(minutes: 5)),
        operationIds: const {'stale'},
      );

      expect(recovered.successData, 1);
      final stored = (await repository.list('7')).successData.single;
      expect(stored.state, OutboxState.retryableFailure);
      expect(stored.requiresStatusProbe, isTrue);
      expect(stored.syncingStartedAt, isNull);
    },
  );

  test(
    'completed status too near expiry enters attention without replay',
    () async {
      await repository.enqueue(operation('lease'));
      final current = (await repository.list('7')).successData.single;
      await repository.confirm(
        accountId: '7',
        operationId: 'lease',
        reviewStamp: context.reviewStamp,
        expectedUpdatedAt: current.updatedAt,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'lease',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'lease',
        next: OutboxState.retryableFailure,
        failure: const NetworkFailure(),
      );
      await repository.retryNow(accountId: '7', operationId: 'lease');
      final status = _Status(
        Success(
          OperationStatus(
            state: OperationState.completed,
            statusCode: 200,
            expiresAt: now.add(const Duration(seconds: 5)),
          ),
        ),
      );
      final handler = _Handler();
      final executor = OutboxExecutor(
        repository: repository,
        networkStatusService: _Online(),
        statusDataSource: status,
        handlers: [handler],
        contextReader: () => context,
        now: () => now,
        minimumReplayWindow: const Duration(seconds: 15),
      );

      final report = await executor.execute(
        OutboxReview(
          operationIds: const {'lease'},
          accountId: '7',
          warehouseId: 11,
          permissionStamp: context.permissionStamp,
        ),
      );

      expect(handler.calls, 0);
      expect(report.failure, isA<StateFailure>());
      expect(
        (await repository.list('7')).successData.single.state,
        OutboxState.permanentFailure,
      );
    },
  );

  test('recovered syncing probes status before original handler', () async {
    await repository.enqueue(operation('recovered'));
    final current = (await repository.list('7')).successData.single;
    await repository.confirm(
      accountId: '7',
      operationId: 'recovered',
      reviewStamp: context.reviewStamp,
      expectedUpdatedAt: current.updatedAt,
    );
    await repository.transition(
      accountId: '7',
      operationId: 'recovered',
      next: OutboxState.syncing,
    );
    now = initial.add(const Duration(minutes: 6));
    final status = _Status(const FailureResult(NotFoundFailure()));
    final handler = _Handler();
    final executor = OutboxExecutor(
      repository: repository,
      networkStatusService: _Online(),
      statusDataSource: status,
      handlers: [handler],
      contextReader: () => context,
      now: () => now,
    );

    final report = await executor.execute(
      OutboxReview(
        operationIds: const {'recovered'},
        accountId: '7',
        warehouseId: 11,
        permissionStamp: context.permissionStamp,
      ),
    );

    expect(status.calls, 1);
    expect(handler.calls, 1);
    expect(report.succeededOperationIds, ['recovered']);
  });

  test('stale recovery cannot mutate an unreviewed other warehouse', () async {
    await repository.enqueue(operation('visible'));
    await repository.enqueue(operation('other-warehouse', warehouseId: 12));
    for (final id in ['visible', 'other-warehouse']) {
      final current = (await repository.list(
        '7',
      )).successData.singleWhere((item) => item.operationId == id);
      await repository.confirm(
        accountId: '7',
        operationId: id,
        reviewStamp: context.reviewStamp,
        expectedUpdatedAt: current.updatedAt,
      );
      await repository.transition(
        accountId: '7',
        operationId: id,
        next: OutboxState.syncing,
      );
    }
    now = initial.add(const Duration(minutes: 6));
    final executor = OutboxExecutor(
      repository: repository,
      networkStatusService: _Online(),
      statusDataSource: _Status(const FailureResult(NotFoundFailure())),
      handlers: [_Handler()],
      contextReader: () => context,
      now: () => now,
    );

    await executor.execute(
      OutboxReview(
        operationIds: const {'visible'},
        accountId: '7',
        warehouseId: 11,
        permissionStamp: context.permissionStamp,
      ),
    );

    final hidden = (await repository.list(
      '7',
    )).successData.singleWhere((item) => item.operationId == 'other-warehouse');
    expect(hidden.state, OutboxState.syncing);
  });

  test(
    'simultaneous foreground triggers are rejected before preflight',
    () async {
      await repository.enqueue(operation('simultaneous'));
      final current = (await repository.list('7')).successData.single;
      await repository.confirm(
        accountId: '7',
        operationId: 'simultaneous',
        reviewStamp: context.reviewStamp,
        expectedUpdatedAt: current.updatedAt,
      );
      final executor = OutboxExecutor(
        repository: repository,
        networkStatusService: _Online(),
        statusDataSource: _Status(const FailureResult(NotFoundFailure())),
        handlers: [_Handler()],
        contextReader: () => context,
        now: () => now,
      );
      final review = OutboxReview(
        operationIds: const {'simultaneous'},
        accountId: '7',
        warehouseId: 11,
        permissionStamp: context.permissionStamp,
      );

      final reports = await Future.wait([
        executor.execute(review),
        executor.execute(review),
      ]);

      expect(
        reports.where(
          (report) =>
              report.failure is StateFailure &&
              report.failure!.message.contains('already running'),
        ),
        hasLength(1),
      );
    },
  );

  test('VM filters scope and rejects cross-warehouse mutation', () async {
    await repository.enqueue(operation('visible'));
    await repository.enqueue(operation('hidden', warehouseId: 12));
    final vm = SyncCenterViewModel(
      repository: repository,
      executor: _Executor(),
      contextReader: () => context,
    );
    addTearDown(vm.dispose);

    await vm.load();
    expect(vm.operations.map((item) => item.operationId), ['visible']);
    await vm.cancel('hidden');

    expect(vm.commandFailure, isA<AuthorizationFailure>());
    expect(
      (await repository.list(
        '7',
      )).successData.singleWhere((item) => item.operationId == 'hidden').state,
      OutboxState.queued,
    );
  });

  test(
    'refresh cannot release command lock or erase command failure',
    () async {
      await repository.enqueue(operation('op'));
      final blocking = _BlockingExecutor();
      final vm = SyncCenterViewModel(
        repository: repository,
        executor: blocking,
        contextReader: () => context,
      );
      addTearDown(vm.dispose);
      await vm.load();
      await vm.review('op');

      final first = vm.retryAllReviewed();
      await blocking.started.future;
      await vm.refreshContext();
      expect(vm.isBusy, isTrue);
      await vm.cancel('op');
      expect(vm.commandFailure, isA<StateFailure>());
      blocking.release.complete();
      await first;
      expect(vm.commandFailure, isA<StateFailure>());
      vm.dismissCommandFailure();
      expect(vm.commandFailure, isNull);
    },
  );
}

final class _Online implements NetworkStatusService {
  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  NetworkReachability get current => NetworkReachability.online;

  @override
  Future<NetworkReachability> verify() async => NetworkReachability.online;

  @override
  void markOnlineFromRequest() {}

  @override
  Future<void> dispose() async {}
}

final class _Status implements OperationStatusRemoteDataSource {
  _Status(this.result);
  final Result<OperationStatus> result;
  int calls = 0;

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async {
    calls += 1;
    return result;
  }
}

final class _Handler implements OutboxOperationHandler {
  int calls = 0;
  @override
  OutboxOperationKind get kind => OutboxOperationKind.documentCreate;
  @override
  String get statusScope => 'documents';
  @override
  Future<Result<Object?>> execute(OutboxOperation operation) async {
    calls += 1;
    return const Success(null);
  }
}

class _Executor implements OutboxExecutorPort {
  @override
  Future<OutboxExecutionReport> execute(OutboxReview review) async =>
      const OutboxExecutionReport();
}

final class _BlockingExecutor extends _Executor {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<OutboxExecutionReport> execute(OutboxReview review) async {
    started.complete();
    await release.future;
    return const OutboxExecutionReport();
  }
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;
}
