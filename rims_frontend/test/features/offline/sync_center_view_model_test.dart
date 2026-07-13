import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
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
}) {
  final now = DateTime.utc(2026, 7, 13);
  return OutboxOperation(
    operationId: id,
    idempotencyKey: key ?? 'key-$id',
    accountId: '7',
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: payload,
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: confirmed ? now : null,
  );
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
