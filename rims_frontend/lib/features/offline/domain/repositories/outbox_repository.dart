import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../entities/outbox_operation.dart';

abstract interface class OutboxRepository {
  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  });

  Future<Result<List<OutboxOperation>>> list(String accountId);

  Future<Result<List<OutboxOperation>>> ready(String accountId);

  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  });

  Future<Result<OutboxOperation>> cancel({
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
