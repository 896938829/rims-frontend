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

  Future<void> saveDraft(DocumentDraft draft, {int? expectedVersion});

  Future<List<DocumentDraft>> listDrafts(String accountId);

  Future<void> deleteDraft({
    required String accountId,
    required String draftId,
  });

  Future<void> pruneDrafts(DateTime updatedBefore);

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

abstract interface class ConditionalCacheRecordStorage {
  Future<bool> deleteCacheRecordIfPayloadMatches({
    required CacheKey key,
    required int schemaVersion,
    required String payloadField,
    required Object? expectedValue,
  });
}

abstract interface class AuthSessionProjectionTransactionStorage {
  bool get supportsAuthSessionProjectionTransactions;

  Future<bool> saveAuthSessionProjectionIfCurrent(
    CacheRecord record, {
    required String ownerId,
    required int attemptVersion,
  });

  Future<bool> deleteAuthSessionProjectionIfOwned({
    required CacheKey key,
    required int schemaVersion,
    required String ownerId,
    required int attemptVersion,
  });
}
