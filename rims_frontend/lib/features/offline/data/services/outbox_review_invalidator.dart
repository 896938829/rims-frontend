import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/offline_ownership_service.dart';

final class OutboxReviewInvalidator implements OfflineReviewInvalidator {
  const OutboxReviewInvalidator({required this.repository});

  final OutboxRepository repository;

  @override
  Future<void> invalidate({required String accountId, int? warehouseId}) async {
    final listed = await repository.list(accountId);
    if (listed case FailureResult<List<OutboxOperation>>(:final failure)) {
      throw StateError(failure.message);
    }
    final operations = (listed as Success<List<OutboxOperation>>).data;
    final expectedUpdatedAt = <String, DateTime>{
      for (final operation in operations)
        if ((warehouseId == null || operation.warehouseId == warehouseId) &&
            (operation.confirmedAt != null || operation.reviewStamp != null))
          operation.operationId: operation.updatedAt,
    };
    if (expectedUpdatedAt.isEmpty) return;
    final invalidated = await repository.invalidateReviewGraph(
      accountId: accountId,
      expectedUpdatedAtByOperation: expectedUpdatedAt,
    );
    if (invalidated case FailureResult<List<OutboxOperation>>(:final failure)) {
      throw StateError(failure.message);
    }
  }
}
