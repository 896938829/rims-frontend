import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/app.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_permission_policy.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/sync_center_view_model.dart';

void main() {
  late MemoryOutboxRepository repository;
  late _Executor executor;
  late OutboxExecutionContext context;
  late SyncCenterViewModel viewModel;

  Future<void> transition(String id, OutboxState state) async {
    await repository.transition(accountId: '7', operationId: id, next: state);
  }

  setUp(() {
    repository = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    executor = _Executor();
    context = const OutboxExecutionContext(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'role:operator@1',
      allowedKinds: {OutboxOperationKind.documentCreate},
    );
    viewModel = SyncCenterViewModel(
      repository: repository,
      executor: executor,
      contextReader: () => context,
    );
  });

  tearDown(() => viewModel.dispose());

  test('late session refresh is safe after route disposal', () async {
    viewModel.dispose();

    await expectLater(viewModel.refreshContext(), completes);
  });

  test('groups waiting attention and completed operations', () async {
    await repository.enqueue(_operation('waiting'));
    await repository.enqueue(_operation('attention'));
    await transition('attention', OutboxState.syncing);
    await transition('attention', OutboxState.conflict);
    await repository.enqueue(_operation('completed'));
    await transition('completed', OutboxState.syncing);
    await transition('completed', OutboxState.succeeded);

    await viewModel.load();

    expect(viewModel.waiting.map((item) => item.operationId), ['waiting']);
    expect(viewModel.attention.map((item) => item.operationId), ['attention']);
    expect(viewModel.completed.map((item) => item.operationId), ['completed']);
  });

  test(
    'review is explicit and retry all executes only reviewed operations',
    () async {
      await repository.enqueue(_operation('reviewed'));
      await repository.enqueue(_operation('unreviewed'));
      await viewModel.load();

      await viewModel.review('reviewed');
      await viewModel.retryAllReviewed();

      expect(viewModel.reviewedOperationIds, {'reviewed'});
      expect(executor.reviews.single.operationIds, {'reviewed'});
    },
  );

  test('review persistently confirms an unconfirmed operation', () async {
    await repository.enqueue(_operation('op', confirmed: false));
    await viewModel.load();

    await viewModel.review('op');

    final stored = (await repository.list('7')).dataOrNull!.single;
    expect(stored.isConfirmed, isTrue);
  });

  test('manual retry clears backoff for a reviewed selection', () async {
    await repository.enqueue(_operation('op'));
    await repository.transition(
      accountId: '7',
      operationId: 'op',
      next: OutboxState.syncing,
    );
    await repository.transition(
      accountId: '7',
      operationId: 'op',
      next: OutboxState.retryableFailure,
    );
    await viewModel.load();
    await viewModel.review('op');
    viewModel.setSelected('op', true);

    await viewModel.retrySelected();

    final stored = (await repository.list('7')).dataOrNull!.single;
    expect(stored.nextAttemptAt, isNull);
  });

  test('account warehouse or permission change requires re-review', () async {
    await repository.enqueue(_operation('op'));
    await viewModel.load();
    await viewModel.review('op');

    for (final changed in [
      const OutboxExecutionContext(
        accountId: '8',
        warehouseId: 11,
        permissionStamp: 'role:operator@1',
        allowedKinds: {OutboxOperationKind.documentCreate},
      ),
      const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 12,
        permissionStamp: 'role:operator@1',
        allowedKinds: {OutboxOperationKind.documentCreate},
      ),
      const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'role:operator@2',
        allowedKinds: {OutboxOperationKind.documentCreate},
      ),
    ]) {
      context = changed;
      await viewModel.refreshContext();
      expect(viewModel.reviewedOperationIds, isEmpty);
      context = const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'role:operator@1',
        allowedKinds: {OutboxOperationKind.documentCreate},
      );
      await viewModel.refreshContext();
      await viewModel.review('op');
    }
  });

  test(
    'same-role permission revocation invalidates controlled review',
    () async {
      const policy = OutboxPermissionPolicy();
      const granted = AppUser(
        id: 7,
        username: 'operator',
        realName: 'Operator',
        roleCode: 'operator',
        roleName: 'Operator',
        permissionCodes: {'document:create'},
      );
      const revoked = AppUser(
        id: 7,
        username: 'operator',
        realName: 'Operator',
        roleCode: 'operator',
        roleName: 'Operator',
        permissionCodes: {},
      );
      context = policy.contextFor(user: granted, warehouseId: 11);
      await repository.enqueue(_operation('op'));
      await viewModel.load();
      await viewModel.review('op');

      context = policy.contextFor(user: revoked, warehouseId: 11);
      await viewModel.refreshContext();

      expect(viewModel.reviewedOperationIds, isEmpty);
    },
  );

  test(
    'retry selected excludes selected operations that are not reviewed',
    () async {
      await repository.enqueue(_operation('a'));
      await repository.enqueue(_operation('b'));
      await viewModel.load();
      viewModel.setSelected('a', true);
      viewModel.setSelected('b', true);
      await viewModel.review('a');

      await viewModel.retrySelected();

      expect(executor.reviews.single.operationIds, {'a'});
    },
  );

  test(
    'slow account A load cannot overwrite fast account B generation',
    () async {
      viewModel.dispose();
      final deferred = _DeferredRepository(repository);
      final loadA = Completer<Result<List<OutboxOperation>>>();
      final loadB = Completer<Result<List<OutboxOperation>>>();
      deferred.listResults.addAll([loadA, loadB]);
      viewModel = SyncCenterViewModel(
        repository: deferred,
        executor: executor,
        contextReader: () => context,
      );
      final operationA = _operation('a');
      final operationB = _operation('b', accountId: '8');

      final slow = viewModel.load();
      final generationA = viewModel.contextGeneration;
      context = const OutboxExecutionContext(
        accountId: '8',
        warehouseId: 11,
        permissionStamp: 'role:operator@1',
        allowedKinds: {OutboxOperationKind.documentCreate},
      );
      final fast = viewModel.refreshContext();
      final generationB = viewModel.contextGeneration;
      loadB.complete(Success([operationB]));
      await fast;
      loadA.complete(Success([operationA]));
      await slow;

      expect(generationB, greaterThan(generationA));
      expect(viewModel.operations.map((item) => item.operationId), ['b']);
    },
  );

  test('late review result cannot enter a newer context', () async {
    await repository.enqueue(_operation('a'));
    await repository.enqueue(_operation('b', accountId: '8'));
    viewModel.dispose();
    final deferred = _DeferredRepository(repository);
    viewModel = SyncCenterViewModel(
      repository: deferred,
      executor: executor,
      contextReader: () => context,
    );
    await viewModel.load();
    final confirmA = Completer<Result<OutboxOperation>>();
    deferred.confirmResult = confirmA;
    final lateReview = viewModel.review('a');

    context = const OutboxExecutionContext(
      accountId: '8',
      warehouseId: 11,
      permissionStamp: 'role:operator@1',
      allowedKinds: {OutboxOperationKind.documentCreate},
    );
    await viewModel.refreshContext();
    confirmA.complete(const FailureResult(AuthorizationFailure()));

    expect(await lateReview, isFalse);
    expect(viewModel.operations.map((item) => item.operationId), ['b']);
    expect(viewModel.reviewedOperationIds, isEmpty);
    expect(viewModel.failure, isNull);
    expect(viewModel.isBusy, isFalse);
  });

  test('retry command drops stale reviewed ids before route refresh', () async {
    await repository.enqueue(_operation('a'));
    await viewModel.load();
    await viewModel.review('a');
    viewModel.setSelected('a', true);
    context = const OutboxExecutionContext(
      accountId: '8',
      warehouseId: 11,
      permissionStamp: 'role:operator@1',
      allowedKinds: {OutboxOperationKind.documentCreate},
    );

    await viewModel.retrySelected();

    expect(executor.reviews, isEmpty);
    expect(viewModel.reviewedOperationIds, isEmpty);
    expect(viewModel.selectedOperationIds, isEmpty);
    expect(viewModel.failure, isNull);
    expect(viewModel.operations, isEmpty);
  });

  test(
    'late mutation self-invalidates busy state before route refresh',
    () async {
      await repository.enqueue(_operation('a'));
      viewModel.dispose();
      final deferred = _DeferredRepository(repository);
      viewModel = SyncCenterViewModel(
        repository: deferred,
        executor: executor,
        contextReader: () => context,
      );
      await viewModel.load();
      final cancelA = Completer<Result<OutboxOperation>>();
      deferred.cancelResult = cancelA;
      final lateCancel = viewModel.cancel('a');
      expect(viewModel.isBusy, isTrue);
      context = const OutboxExecutionContext(
        accountId: '8',
        warehouseId: 11,
        permissionStamp: 'role:operator@1',
        allowedKinds: {OutboxOperationKind.documentCreate},
      );
      cancelA.complete(const FailureResult(AuthorizationFailure()));

      await lateCancel;

      expect(viewModel.isBusy, isFalse);
      expect(viewModel.failure, isNull);
      expect(viewModel.operations, isEmpty);
    },
  );

  test('memory store legacy and Sync Center share one app outbox', () async {
    final store = MemoryOfflineStore();
    final appRepository = outboxRepositoryForOfflineStore(store);
    expect(identical(appRepository, store.outboxRepository), isTrue);
    final operation = _operation('legacy');

    await store.enqueue(operation, const {});
    await store.transition('legacy', OutboxState.syncing);

    expect(
      (await appRepository.list('7')).dataOrNull!.single.state,
      OutboxState.syncing,
    );
    await store.clearAccount('7');
    expect((await appRepository.list('7')).dataOrNull, isEmpty);
  });

  test('inventory confirmation summarizes immutable review facts', () async {
    await repository.enqueue(
      _operation(
        'stock',
        payload: const {
          'warehouseName': 'North Depot',
          'documentType': 'Stocktake',
          'lines': [
            {'sku': 'A', 'quantity': 2},
            {'sku': 'B', 'quantity': 1},
          ],
          'staleAssumptions': ['Stock was last checked 2 hours ago'],
        },
      ),
    );
    await viewModel.load();

    final summary = viewModel.confirmationSummary('stock');

    expect(summary.warehouse, 'North Depot');
    expect(summary.documentType, 'Stocktake');
    expect(summary.lineCount, 2);
    expect(summary.staleAssumptions, ['Stock was last checked 2 hours ago']);
  });

  test(
    'cancel discard and conflict resolution delegate without rewriting',
    () async {
      await repository.enqueue(_operation('cancel'));
      await repository.enqueue(
        _operation('conflict', payload: const {'quantity': 1}),
      );
      await transition('conflict', OutboxState.syncing);
      await transition('conflict', OutboxState.conflict);
      await viewModel.load();

      await viewModel.cancel('cancel');
      final replacement = _operation(
        'replacement',
        key: 'replacement-key',
        payload: const {'quantity': 2},
      );
      await viewModel.resolveConflict('conflict', replacement);
      await viewModel.discard('cancel');

      final operations = (await repository.list('7')).dataOrNull!;
      expect(operations.any((item) => item.operationId == 'cancel'), isFalse);
      expect(
        operations
            .singleWhere((item) => item.operationId == 'conflict')
            .payload,
        const {'quantity': 1},
      );
      expect(
        operations
            .singleWhere((item) => item.operationId == 'replacement')
            .payload,
        const {'quantity': 2},
      );
    },
  );
}

OutboxOperation _operation(
  String id, {
  String? key,
  Map<String, Object?> payload = const {},
  bool confirmed = true,
  String accountId = '7',
}) {
  final now = DateTime.utc(2026, 7, 13);
  return OutboxOperation(
    operationId: id,
    idempotencyKey: key ?? 'key-$id',
    accountId: accountId,
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: payload,
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: confirmed ? now : null,
  );
}

final class _DeferredRepository implements OutboxRepository {
  _DeferredRepository(this.delegate);

  final OutboxRepository delegate;
  final Queue<Completer<Result<List<OutboxOperation>>>> listResults = Queue();
  Completer<Result<OutboxOperation>>? confirmResult;
  Completer<Result<OutboxOperation>>? cancelResult;

  @override
  Future<Result<List<OutboxOperation>>> list(String accountId) =>
      listResults.isEmpty
      ? delegate.list(accountId)
      : listResults.removeFirst().future;

  @override
  Future<Result<OutboxOperation>> confirm({
    required String accountId,
    required String operationId,
    String? reviewStamp,
    DateTime? expectedUpdatedAt,
  }) =>
      confirmResult?.future ??
      delegate.confirm(
        accountId: accountId,
        operationId: operationId,
        reviewStamp: reviewStamp,
        expectedUpdatedAt: expectedUpdatedAt,
      );

  @override
  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  }) => delegate.enqueue(operation, dependencies: dependencies);

  @override
  Future<Result<List<OutboxOperation>>> ready(
    String accountId, {
    String? reviewStamp,
  }) => delegate.ready(accountId, reviewStamp: reviewStamp);

  @override
  Future<Result<int>> recoverStaleSyncing({
    required String accountId,
    required DateTime staleBefore,
    required Set<String> operationIds,
  }) => delegate.recoverStaleSyncing(
    accountId: accountId,
    staleBefore: staleBefore,
    operationIds: operationIds,
  );

  @override
  Future<Result<OutboxOperation>> retryNow({
    required String accountId,
    required String operationId,
  }) => delegate.retryNow(accountId: accountId, operationId: operationId);

  @override
  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  }) => delegate.transition(
    accountId: accountId,
    operationId: operationId,
    next: next,
    failure: failure,
  );

  @override
  Future<Result<OutboxOperation>> cancel({
    required String accountId,
    required String operationId,
  }) =>
      cancelResult?.future ??
      delegate.cancel(accountId: accountId, operationId: operationId);

  @override
  Future<Result<OutboxOperation>> discard({
    required String accountId,
    required String operationId,
  }) => delegate.discard(accountId: accountId, operationId: operationId);

  @override
  Future<Result<OutboxOperation>> resolveConflict({
    required String accountId,
    required String conflictedOperationId,
    required OutboxOperation replacement,
    Set<String> dependencies = const {},
  }) => delegate.resolveConflict(
    accountId: accountId,
    conflictedOperationId: conflictedOperationId,
    replacement: replacement,
    dependencies: dependencies,
  );

  @override
  Future<Result<void>> clearAccount(String accountId) =>
      delegate.clearAccount(accountId);

  @override
  Future<Result<int>> prune({required String accountId}) =>
      delegate.prune(accountId: accountId);
}

final class _Executor implements OutboxExecutorPort {
  final List<OutboxReview> reviews = [];

  @override
  Future<OutboxExecutionReport> execute(OutboxReview review) async {
    reviews.add(review);
    return const OutboxExecutionReport();
  }
}

extension<T> on Result<T> {
  T? get dataOrNull => when(success: (data) => data, failure: (_) => null);
}
