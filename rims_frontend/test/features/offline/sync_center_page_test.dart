import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/presentation/pages/sync_center_page.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/sync_center_view_model.dart';

void main() {
  testWidgets('command FailureBand survives reload until dismissed', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 7, 13);
    final repository = MemoryOutboxRepository(
      stateMachine: OutboxStateMachine(now: () => now),
      now: () => now,
    );
    await repository.enqueue(
      OutboxOperation(
        operationId: 'visible',
        idempotencyKey: 'key-visible',
        accountId: '7',
        warehouseId: 11,
        kind: OutboxOperationKind.documentCreate,
        payload: const {},
        state: OutboxState.queued,
        createdAt: now,
      ),
    );
    const context = OutboxExecutionContext(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'document:create',
      allowedKinds: {OutboxOperationKind.documentCreate},
    );
    final viewModel = SyncCenterViewModel(
      repository: repository,
      executor: const _Executor(),
      contextReader: () => context,
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();
    await viewModel.cancel('outside-current-scope');

    await tester.pumpWidget(
      MaterialApp(home: SyncCenterPage(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-command-failure')), findsOneWidget);

    await viewModel.refreshContext();
    await tester.pump();
    expect(find.byKey(const ValueKey('sync-command-failure')), findsOneWidget);

    await tester.tap(find.byTooltip('关闭错误'));
    await tester.pump();
    expect(find.byKey(const ValueKey('sync-command-failure')), findsNothing);
  });
}

final class _Executor implements OutboxExecutorPort {
  const _Executor();

  @override
  Future<OutboxExecutionReport> execute(OutboxReview review) async =>
      const OutboxExecutionReport();
}
