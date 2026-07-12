import '../../../../core/result/failure.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/services/offline_store.dart';

final class MemoryOfflineStore implements OfflineStore {
  final Map<String, CacheRecord> _cache = {};
  final Map<String, DocumentDraft> _drafts = {};
  final Map<String, OutboxOperation> _operations = {};
  final Map<String, Set<String>> _dependencies = {};

  @override
  Future<void> writeCache(CacheRecord record) async {
    _cache[_cacheKey(record.key, record.schemaVersion)] = record;
  }

  @override
  Future<CacheRecord?> readCache(CacheKey key) async {
    final matches = _cache.values.where((record) => _sameKey(record.key, key));
    if (matches.isEmpty) return null;
    return matches.reduce(
      (current, candidate) =>
          candidate.schemaVersion > current.schemaVersion ? candidate : current,
    );
  }

  @override
  Future<void> saveDraft(DocumentDraft draft) async {
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
  Future<void> enqueue(
    OutboxOperation operation,
    Set<String> dependencies,
  ) async {
    if (dependencies.contains(operation.operationId)) {
      throw ArgumentError.value(operation.operationId, 'dependencies');
    }
    final accountOperations = _operations.values.where(
      (candidate) => candidate.accountId == operation.accountId,
    );
    if (accountOperations.length >= 500) {
      throw StateError('The offline outbox limit is 500 operations.');
    }
    if (accountOperations.any(
      (candidate) => candidate.idempotencyKey == operation.idempotencyKey,
    )) {
      throw StateError('The idempotency key already exists for this account.');
    }
    for (final dependency in dependencies) {
      final parent = _operations[dependency];
      if (parent == null || parent.accountId != operation.accountId) {
        throw StateError(
          'Every dependency must exist and belong to the same account.',
        );
      }
    }
    _operations[operation.operationId] = operation;
    _dependencies[operation.operationId] = Set.unmodifiable(dependencies);
  }

  @override
  Future<List<OutboxOperation>> readyOperations(String accountId) async {
    final result =
        _operations.values.where((operation) {
            if (operation.accountId != accountId ||
                operation.state != OutboxState.queued ||
                !operation.isConfirmed) {
              return false;
            }
            return (_dependencies[operation.operationId] ?? const <String>{})
                .every((id) => _operations[id]?.state == OutboxState.succeeded);
          }).toList()
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List.unmodifiable(result);
  }

  @override
  Future<void> transition(
    String operationId,
    OutboxState next, {
    Failure? failure,
  }) async {
    final current = _operations[operationId];
    if (current == null) {
      throw StateError('The offline operation does not exist.');
    }
    if (!isOutboxTransitionAllowed(current.state, next)) {
      throw StateError(
        'Invalid offline operation transition: ${current.state.wireValue} -> '
        '${next.wireValue}.',
      );
    }
    _operations[operationId] = OutboxOperation(
      operationId: current.operationId,
      idempotencyKey: current.idempotencyKey,
      accountId: current.accountId,
      warehouseId: current.warehouseId,
      kind: current.kind,
      payload: current.payload,
      state: next,
      createdAt: current.createdAt,
      confirmedAt: current.confirmedAt,
      nextAttemptAt: current.nextAttemptAt,
      attemptCount: current.attemptCount,
      lastFailureCode: failure?.runtimeType.toString(),
    );
  }

  @override
  Future<void> clearAccount(String accountId) async {
    _cache.removeWhere((_, record) => record.key.accountId == accountId);
    _drafts.removeWhere((_, draft) => draft.accountId == accountId);
    final ids = _operations.values
        .where((operation) => operation.accountId == accountId)
        .map((operation) => operation.operationId)
        .toSet();
    _operations.removeWhere((id, _) => ids.contains(id));
    _dependencies.removeWhere(
      (id, parents) => ids.contains(id) || parents.any(ids.contains),
    );
  }

  @override
  Future<void> prune(DateTime now) async {
    _cache.removeWhere((_, record) => record.expiresAt.isBefore(now));
  }
}

String _cacheKey(CacheKey key, int schemaVersion) =>
    '${key.accountId}\u0000${key.warehouseId}\u0000${key.namespace}'
    '\u0000${key.entityKey}\u0000$schemaVersion';

bool _sameKey(CacheKey left, CacheKey right) =>
    left.accountId == right.accountId &&
    left.warehouseId == right.warehouseId &&
    left.namespace == right.namespace &&
    left.entityKey == right.entityKey;
