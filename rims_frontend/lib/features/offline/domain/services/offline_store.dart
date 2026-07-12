import '../../../../core/result/failure.dart';
import '../entities/cache_snapshot.dart';
import '../entities/document_draft.dart';
import '../entities/outbox_operation.dart';

abstract interface class OfflineStore {
  Future<void> writeCache(CacheRecord record);

  Future<CacheRecord?> readCache(CacheKey key);

  Future<void> saveDraft(DocumentDraft draft);

  Future<List<DocumentDraft>> listDrafts(String accountId);

  Future<void> enqueue(OutboxOperation operation, Set<String> dependencies);

  Future<List<OutboxOperation>> readyOperations(String accountId);

  Future<void> transition(
    String operationId,
    OutboxState next, {
    Failure? failure,
  });

  Future<void> clearAccount(String accountId);

  Future<void> prune(DateTime now);
}
