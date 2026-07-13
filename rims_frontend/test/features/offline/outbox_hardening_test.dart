import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
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

  test(
    'executor recovers stale syncing before persisted review validation',
    () async {
      await repository.enqueue(operation('invalidated-stale'));
      await repository.transition(
        accountId: '7',
        operationId: 'invalidated-stale',
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
          operationIds: const {'invalidated-stale'},
          accountId: '7',
          warehouseId: 11,
          permissionStamp: context.permissionStamp,
        ),
      );

      final stored = (await repository.list('7')).successData.single;
      expect(report.failure, isA<AuthorizationFailure>());
      expect(stored.state, OutboxState.retryableFailure);
      expect(stored.requiresStatusProbe, isTrue);
      expect(status.calls, 0);
      expect(handler.calls, 0);
    },
  );

  test(
    'non-stale syncing graph stays processing and cannot be reviewed',
    () async {
      await repository.enqueueGraph(
        OutboxGraph(
          operations: [
            operation('upload', kind: OutboxOperationKind.attachmentUpload),
            operation('complete', kind: OutboxOperationKind.documentComplete),
          ],
          dependencies: const {
            'complete': {'upload'},
          },
        ),
      );
      for (final item in (await repository.list('7')).successData) {
        await repository.confirm(
          accountId: '7',
          operationId: item.operationId,
          reviewStamp: 'old-review',
          expectedUpdatedAt: item.updatedAt,
        );
      }
      await repository.transition(
        accountId: '7',
        operationId: 'upload',
        next: OutboxState.syncing,
      );
      const graphContext = OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'files-and-complete',
        allowedKinds: {
          OutboxOperationKind.attachmentUpload,
          OutboxOperationKind.documentComplete,
        },
      );
      final vm = SyncCenterViewModel(
        repository: repository,
        executor: _Executor(),
        contextReader: () => graphContext,
        now: () => now,
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(await vm.review('upload'), isFalse);
      expect(vm.commandFailure, isA<StateFailure>());
      final stored = (await repository.list('7')).successData;
      expect(
        stored.singleWhere((item) => item.operationId == 'upload').state,
        OutboxState.syncing,
      );
      expect(
        stored
            .singleWhere((item) => item.operationId == 'complete')
            .reviewStamp,
        'old-review',
      );
    },
  );

  test(
    'rebuilt permission-blocked graph recovers then probes before remaining work',
    () async {
      await repository.enqueueGraph(
        OutboxGraph(
          operations: [
            operation('create'),
            operation('upload', kind: OutboxOperationKind.attachmentUpload),
            operation('complete', kind: OutboxOperationKind.documentComplete),
          ],
          dependencies: const {
            'upload': {'create'},
            'complete': {'upload'},
          },
        ),
      );
      for (final item in (await repository.list('7')).successData) {
        await repository.confirm(
          accountId: '7',
          operationId: item.operationId,
          reviewStamp: '7\u000011\u0000all@1',
          expectedUpdatedAt: item.updatedAt,
        );
      }
      await repository.transition(
        accountId: '7',
        operationId: 'create',
        next: OutboxState.syncing,
      );
      await repository.completeSuccess(
        accountId: '7',
        operationId: 'create',
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
      );
      await repository.transition(
        accountId: '7',
        operationId: 'upload',
        next: OutboxState.syncing,
      );

      var graphContext = const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'denied@2',
        allowedKinds: {
          OutboxOperationKind.documentCreate,
          OutboxOperationKind.attachmentUpload,
        },
      );
      final deniedVm = SyncCenterViewModel(
        repository: repository,
        executor: _Executor(),
        contextReader: () => graphContext,
        now: () => now,
      );
      await deniedVm.load();
      expect(deniedVm.permissionBlockedOperationIds, {'upload', 'complete'});
      expect(deniedVm.completed.map((operation) => operation.operationId), [
        'create',
      ]);
      deniedVm.dispose();

      now = initial.add(const Duration(minutes: 6));
      graphContext = const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'all@3',
        allowedKinds: {
          OutboxOperationKind.documentCreate,
          OutboxOperationKind.attachmentUpload,
          OutboxOperationKind.documentComplete,
        },
      );
      final events = <String>[];
      final status = _Status(
        const FailureResult(NotFoundFailure()),
        onCall: () => events.add('status:upload'),
      );
      final createHandler = _Handler(events: events);
      final uploadHandler = _Handler(
        kind: OutboxOperationKind.attachmentUpload,
        events: events,
      );
      final completeHandler = _Handler(
        kind: OutboxOperationKind.documentComplete,
        events: events,
      );
      final executor = OutboxExecutor(
        repository: repository,
        networkStatusService: _Online(),
        statusDataSource: status,
        handlers: [createHandler, uploadHandler, completeHandler],
        contextReader: () => graphContext,
        now: () => now,
      );
      final rebuilt = SyncCenterViewModel(
        repository: repository,
        executor: executor,
        contextReader: () => graphContext,
        now: () => now,
      );
      addTearDown(rebuilt.dispose);
      await rebuilt.load();

      expect(await rebuilt.review('upload'), isTrue);
      expect(rebuilt.reviewedOperationIds, {'upload', 'complete'});
      await rebuilt.retryAllReviewed();

      expect(events, ['status:upload', 'handler:upload', 'handler:complete']);
      expect(createHandler.calls, 0);
      expect(uploadHandler.calls, 1);
      expect(completeHandler.calls, 1);
      expect(status.calls, 1);
      final stored = (await repository.list('7')).successData;
      expect(
        stored.map((item) => item.state),
        everyElement(OutboxState.succeeded),
      );
    },
  );

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
  _Status(this.result, {this.onCall});
  final Result<OperationStatus> result;
  final void Function()? onCall;
  int calls = 0;

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async {
    calls += 1;
    onCall?.call();
    return result;
  }
}

final class _Handler implements OutboxOperationHandler {
  _Handler({this.kind = OutboxOperationKind.documentCreate, this.events});

  int calls = 0;
  @override
  final OutboxOperationKind kind;
  final List<String>? events;
  @override
  String get statusScope => 'documents';
  @override
  Future<Result<OutboxHandlerSuccess>> execute(
    OutboxOperation operation, {
    Map<String, OutboxOperationOutput> dependencyOutputs = const {},
    OutboxHandlerExecutionContext executionContext =
        const OutboxHandlerExecutionContext.unverified(),
  }) async {
    calls += 1;
    events?.add('handler:${operation.operationId}');
    return Success(
      OutboxHandlerSuccess(output: OutboxOperationOutput(version: 1, data: {})),
    );
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
