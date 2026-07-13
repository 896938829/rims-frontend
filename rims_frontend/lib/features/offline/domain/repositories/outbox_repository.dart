import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../entities/outbox_operation.dart';
import '../entities/outbox_graph.dart';
import '../entities/outbox_cleanup_intent.dart';

abstract interface class OutboxRepository {
  Future<Result<List<OutboxOperation>>> enqueueGraph(OutboxGraph graph);

  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  });

  Future<Result<List<OutboxOperation>>> list(String accountId);

  Future<Result<List<OutboxOperation>>> ready(
    String accountId, {
    String? reviewStamp,
  });

  Future<Result<OutboxOperation>> confirm({
    required String accountId,
    required String operationId,
    String? reviewStamp,
    DateTime? expectedUpdatedAt,
  });

  Future<Result<int>> recoverStaleSyncing({
    required String accountId,
    required DateTime staleBefore,
    required Set<String> operationIds,
  });

  Future<Result<OutboxOperation>> retryNow({
    required String accountId,
    required String operationId,
  });

  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  });

  Future<Result<OutboxOperation>> completeSuccess({
    required String accountId,
    required String operationId,
    required OutboxOperationOutput output,
    OutboxCleanupRequest? cleanup,
  });

  Future<Result<Map<String, OutboxOperationOutput>>> loadDependencyOutputs({
    required String accountId,
    required String operationId,
  });

  Future<Result<List<OutboxCleanupIntent>>> listCleanupIntents(
    String accountId,
  );

  Future<Result<void>> recordCleanupFailure({
    required String accountId,
    required String operationId,
    required String failure,
  });

  Future<Result<void>> completeCleanupIntent({
    required String accountId,
    required String operationId,
  });

  Future<Result<OutboxOperation>> cancel({
    required String accountId,
    required String operationId,
  });

  Future<Result<OutboxOperation>> discard({
    required String accountId,
    required String operationId,
  });

  Future<Result<OutboxOperation>> resolveConflict({
    required String accountId,
    required String conflictedOperationId,
    required OutboxOperation replacement,
    Set<String> dependencies = const {},
  });

  Future<Result<void>> clearAccount(String accountId);

  Future<Result<int>> prune({required String accountId});
}

abstract interface class OutboxRepositoryOwner {
  OutboxRepository get outboxRepository;
}
