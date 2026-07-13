import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/data/services/outbox_cleanup_coordinator.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_cleanup_intent.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  test(
    'cleanup failure keeps intent and restart retries without network',
    () async {
      final repository = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      final operation = OutboxOperation(
        operationId: 'operation-1',
        idempotencyKey: 'key-1',
        accountId: '7',
        warehouseId: 11,
        kind: OutboxOperationKind.documentCreate,
        payload: const {},
        state: OutboxState.queued,
        createdAt: DateTime.utc(2026, 7, 13),
        confirmedAt: DateTime.utc(2026, 7, 13),
      );
      await repository.enqueueGraph(OutboxGraph(operations: [operation]));
      await repository.transition(
        accountId: '7',
        operationId: operation.operationId,
        next: OutboxState.syncing,
      );
      await repository.completeSuccess(
        accountId: '7',
        operationId: operation.operationId,
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
        cleanup: OutboxCleanupRequest(
          draftId: 'draft-1',
          attachmentRequestIds: ['file-1'],
        ),
      );
      final staging = _Staging()
        ..failure = const LocalStorageFailure(message: 'locked');
      final drafts = _Drafts();
      final events = <AppEvent>[];
      final eventBus = AppEventBus()..on<AppEvent>().listen(events.add);
      final coordinator = OutboxCleanupCoordinator(
        repository: repository,
        stagingStore: staging,
        draftRepository: drafts,
        eventBus: eventBus,
      );

      await coordinator.run('7');

      expect(
        (await repository.listCleanupIntents('7')).dataOrNull,
        hasLength(1),
      );
      expect(
        (await repository.list('7')).dataOrNull!.single.state,
        OutboxState.succeeded,
      );
      expect(drafts.deleted, isEmpty);

      staging.failure = null;
      final recreated = OutboxCleanupCoordinator(
        repository: repository,
        stagingStore: staging,
        draftRepository: drafts,
        eventBus: eventBus,
      );
      await recreated.run('7');
      await Future<void>.delayed(Duration.zero);

      expect((await repository.listCleanupIntents('7')).dataOrNull, isEmpty);
      expect(staging.calls, 2);
      expect(drafts.deleted, ['draft-1']);
      expect(events.whereType<GlobalRefreshRequestedEvent>(), hasLength(1));
      await eventBus.dispose();
    },
  );
}

extension<T> on Result<T> {
  T? get dataOrNull => switch (this) {
    Success<T>(:final data) => data,
    FailureResult<T>() => null,
  };
}

final class _Staging implements OutboxAttachmentStagingStore {
  Failure? failure;
  int calls = 0;

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async {
    calls += 1;
    return failure == null ? const Success(null) : FailureResult(failure!);
  }

  @override
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) => throw UnimplementedError();
}

final class _Drafts implements DocumentDraftRepository {
  final List<String> deleted = [];

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deleted.add(draftId);
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) => throw UnimplementedError();
  @override
  Future<List<DocumentDraft>> list(String accountId) =>
      throw UnimplementedError();
  @override
  Future<void> prune() => throw UnimplementedError();
  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) => throw UnimplementedError();
}
