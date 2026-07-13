import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/result.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../domain/entities/outbox_cleanup_intent.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/document_draft_repository.dart';
import '../../domain/repositories/outbox_repository.dart';

final class OutboxCleanupCoordinator {
  const OutboxCleanupCoordinator({
    required this.repository,
    required this.stagingStore,
    required this.draftRepository,
    required this.eventBus,
  });

  final OutboxRepository repository;
  final OutboxAttachmentStagingStore stagingStore;
  final DocumentDraftRepository draftRepository;
  final AppEventBus eventBus;

  Future<void> run(String accountId) async {
    final operations = await repository.list(accountId);
    if (operations case FailureResult<List<OutboxOperation>>()) return;
    final operationsById = {
      for (final operation
          in (operations as Success<List<OutboxOperation>>).data)
        operation.operationId: operation,
    };
    final listed = await repository.listCleanupIntents(accountId);
    if (listed case FailureResult<List<OutboxCleanupIntent>>()) return;
    for (final intent in (listed as Success<List<OutboxCleanupIntent>>).data) {
      final operation = operationsById[intent.operationId];
      if (operation == null ||
          operation.state != OutboxState.succeeded ||
          operation.accountId != intent.accountId ||
          operation.warehouseId != intent.warehouseId) {
        continue;
      }
      final failure = await _clean(intent);
      if (failure != null) {
        await repository.recordCleanupFailure(
          accountId: accountId,
          operationId: intent.operationId,
          failure: failure,
        );
        continue;
      }
      final completed = await repository.completeCleanupIntent(
        accountId: accountId,
        operationId: intent.operationId,
      );
      if (completed case Success<void>()) {
        eventBus.publish(const GlobalRefreshRequestedEvent());
      }
    }
  }

  Future<String?> _clean(OutboxCleanupIntent intent) async {
    if (intent.attachmentRequestIds.isNotEmpty) {
      final removed = await stagingStore.removeStagedAttachments(
        userId: intent.accountId,
        requestIds: intent.attachmentRequestIds,
      );
      if (removed case FailureResult<void>(:final failure)) {
        return failure.message;
      }
    }
    if (intent.draftId case final draftId?) {
      try {
        await draftRepository.delete(
          accountId: intent.accountId,
          draftId: draftId,
        );
      } on Object catch (error) {
        return error.toString();
      }
    }
    return null;
  }
}
