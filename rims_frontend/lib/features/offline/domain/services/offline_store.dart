import '../../../../core/result/failure.dart';
import '../entities/cache_snapshot.dart';
import '../entities/document_draft.dart';
import '../entities/outbox_operation.dart';

abstract interface class OfflineStore {
  Future<void> writeCache(CacheRecord record);

  Future<CacheRecord?> readCache(CacheKey key, {int? schemaVersion});

  Future<void> enforceCacheLimit({
    required String accountId,
    required int? warehouseId,
    required String namespace,
    required int maxRecords,
  });

  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  });

  Future<void> deleteCacheNamespace({
    required String accountId,
    required String namespace,
  });

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
