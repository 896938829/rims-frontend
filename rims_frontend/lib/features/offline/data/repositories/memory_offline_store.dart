import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/outbox_state_machine.dart';
import 'memory_outbox_repository.dart';

final class MemoryOfflineStore implements OfflineStore, OutboxRepositoryOwner {
  MemoryOfflineStore({DateTime Function()? now})
    : outboxRepository = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(now: now),
        now: now,
      );

  @override
  final MemoryOutboxRepository outboxRepository;

  final Map<String, CacheRecord> _cache = {};
  final Map<String, DocumentDraft> _drafts = {};
  final Map<String, String> _legacyOperationAccounts = {};

  @override
  Future<void> writeCache(CacheRecord record) async {
    _cache[_cacheKey(record.key, record.schemaVersion)] = record;
  }

  @override
  Future<CacheRecord?> readCache(CacheKey key, {int? schemaVersion}) async {
    final matches = _cache.values.where(
      (record) =>
          _sameKey(record.key, key) &&
          (schemaVersion == null || record.schemaVersion == schemaVersion),
    );
    if (matches.isEmpty) return null;
    return matches.reduce(
      (current, candidate) =>
          candidate.schemaVersion > current.schemaVersion ? candidate : current,
    );
  }

  @override
  Future<void> enforceCacheLimit({
    required String accountId,
    required int? warehouseId,
    required String namespace,
    required int maxRecords,
  }) async {
    if (maxRecords < 1) {
      throw ArgumentError.value(maxRecords, 'maxRecords');
    }
    final matches =
        _cache.entries
            .where(
              (entry) =>
                  entry.value.key.accountId == accountId &&
                  entry.value.key.warehouseId == warehouseId &&
                  entry.value.key.namespace == namespace,
            )
            .toList()
          ..sort(
            (left, right) =>
                right.value.fetchedAt.compareTo(left.value.fetchedAt),
          );
    for (final entry in matches.skip(maxRecords)) {
      _cache.remove(entry.key);
    }
  }

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) async {
    _cache.removeWhere(
      (_, record) =>
          record.key.accountId == accountId &&
          record.key.warehouseId == warehouseId,
    );
  }

  @override
  Future<void> deleteCacheNamespace({
    required String accountId,
    required String namespace,
  }) async {
    _cache.removeWhere(
      (_, record) =>
          record.key.accountId == accountId &&
          record.key.namespace == namespace,
    );
  }

  @override
  Future<void> saveDraft(DocumentDraft draft, {int? expectedVersion}) async {
    final existing = _drafts[draft.id];
    if (expectedVersion != null &&
        ((existing == null && expectedVersion != 0) ||
            (existing != null && existing.version != expectedVersion))) {
      throw StateError('Document draft version conflict.');
    }
    _drafts[draft.id] = draft;
  }

  @override
  Future<List<DocumentDraft>> listDrafts(String accountId) async {
    final result =
        _drafts.values.where((draft) => draft.accountId == accountId).toList()
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List.unmodifiable(result);
  }

  @override
  Future<void> deleteDraft({
    required String accountId,
    required String draftId,
  }) async {
    final draft = _drafts[draftId];
    if (draft?.accountId == accountId) _drafts.remove(draftId);
  }

  @override
  Future<void> pruneDrafts(DateTime updatedBefore) async {
    _drafts.removeWhere((_, draft) => draft.updatedAt.isBefore(updatedBefore));
  }

  @override
  Future<void> enqueue(
    OutboxOperation operation,
    Set<String> dependencies,
  ) async {
    if (operation.replacementOf != null) {
      throw ArgumentError.value(
        operation.replacementOf,
        'operation.replacementOf',
        'Replacement ownership can only be created by conflict resolution.',
      );
    }
    if (dependencies.contains(operation.operationId)) {
      throw ArgumentError.value(operation.operationId, 'dependencies');
    }
    final result = await outboxRepository.enqueue(
      operation,
      dependencies: dependencies,
    );
    _throwLegacyFailure(result);
    _legacyOperationAccounts[operation.operationId] = operation.accountId;
  }

  @override
  Future<List<OutboxOperation>> readyOperations(String accountId) async {
    return _successOrThrow(await outboxRepository.ready(accountId));
  }

  @override
  Future<void> transition(
    String operationId,
    OutboxState next, {
    Failure? failure,
  }) async {
    final accountId = _legacyOperationAccounts[operationId];
    if (accountId == null) {
      throw StateError('The offline operation does not exist.');
    }
    _throwLegacyFailure(
      await outboxRepository.transition(
        accountId: accountId,
        operationId: operationId,
        next: next,
        failure: failure,
      ),
    );
  }

  @override
  Future<void> clearAccount(String accountId) async {
    _cache.removeWhere((_, record) => record.key.accountId == accountId);
    _drafts.removeWhere((_, draft) => draft.accountId == accountId);
    _throwLegacyFailure(await outboxRepository.clearAccount(accountId));
    _legacyOperationAccounts.removeWhere((_, owner) => owner == accountId);
  }

  @override
  Future<void> prune(DateTime now) async {
    _cache.removeWhere((_, record) => record.expiresAt.isBefore(now));
    for (final accountId in _legacyOperationAccounts.values.toSet()) {
      _throwLegacyFailure(await outboxRepository.prune(accountId: accountId));
    }
  }
}

T _successOrThrow<T>(Result<T> result) => result.when(
  success: (data) => data,
  failure: (failure) => throw StateError(failure.message),
);

void _throwLegacyFailure<T>(Result<T> result) {
  _successOrThrow(result);
}

String _cacheKey(CacheKey key, int schemaVersion) =>
    '${key.accountId}\u0000${key.warehouseId}\u0000${key.namespace}'
    '\u0000${key.entityKey}\u0000$schemaVersion';

bool _sameKey(CacheKey left, CacheKey right) =>
    left.accountId == right.accountId &&
    left.warehouseId == right.warehouseId &&
    left.namespace == right.namespace &&
    left.entityKey == right.entityKey;
