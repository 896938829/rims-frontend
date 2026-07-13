import 'dart:async';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../entities/cache_snapshot.dart';
import '../entities/document_draft.dart';
import '../entities/outbox_cleanup_intent.dart';
import '../entities/outbox_graph.dart';
import '../entities/outbox_operation.dart';
import '../repositories/outbox_repository.dart';
import 'offline_ownership_service.dart';
import 'offline_store.dart';

final class OfflineWriteBlockedException implements Exception {
  const OfflineWriteBlockedException(this.accountIds);

  final Set<String> accountIds;

  @override
  String toString() =>
      'Offline writes are blocked for: ${accountIds.join(', ')}';
}

final class OfflineWriteBarrier
    implements OfflineScopedMutationPermitParticipant {
  final Map<String, Set<Object>> _accountBlocks = {};
  final Set<Object> _globalBlocks = {};
  final Map<String, int> _activeByAccount = {};
  int _activeGlobal = 0;
  int _nextBlockId = 0;
  Completer<void> _stateChanged = Completer<void>();

  Future<T> protect<T>({
    required String accountId,
    required Future<T> Function() operation,
  }) => protectAccounts(accountIds: {accountId}, operation: operation);

  Future<T> protectAccounts<T>({
    required Set<String> accountIds,
    required Future<T> Function() operation,
  }) {
    final normalized = Set<String>.unmodifiable(
      accountIds
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    );
    if (normalized.isEmpty) {
      return Future<T>.error(ArgumentError.value(accountIds, 'accountIds'));
    }
    final blockingIds = _blockingIdsForAccounts(normalized);
    final inherited = Zone.current[this];
    final permit = inherited is _WritePermit ? inherited : null;
    final hasPermit =
        permit != null &&
        permit.covers(normalized) &&
        (permit.enteredMutation || permit.blockIds.containsAll(blockingIds));
    if (blockingIds.isNotEmpty && !hasPermit) {
      return Future<T>.error(OfflineWriteBlockedException(normalized));
    }
    for (final accountId in normalized) {
      _activeByAccount.update(
        accountId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    _signalStateChange();
    final effectivePermit = hasPermit
        ? permit
        : _WritePermit(
            accountIds: normalized,
            global: false,
            blockIds: blockingIds,
            enteredMutation: true,
          );
    final future = runZoned(
      () => Future<T>.sync(operation),
      zoneValues: {this: effectivePermit},
    );
    return future.whenComplete(() {
      for (final accountId in normalized) {
        final remaining = (_activeByAccount[accountId] ?? 1) - 1;
        if (remaining == 0) {
          _activeByAccount.remove(accountId);
        } else {
          _activeByAccount[accountId] = remaining;
        }
      }
      _signalStateChange();
    });
  }

  Future<T> protectAll<T>(Future<T> Function() operation) {
    final blockingIds = _allBlockingIds();
    final inherited = Zone.current[this];
    final permit = inherited is _WritePermit ? inherited : null;
    final hasPermit =
        permit != null &&
        permit.global &&
        (permit.enteredMutation || permit.blockIds.containsAll(blockingIds));
    if (blockingIds.isNotEmpty && !hasPermit) {
      return Future<T>.error(
        OfflineWriteBlockedException(_accountBlocks.keys.toSet()),
      );
    }
    _activeGlobal += 1;
    _signalStateChange();
    final effectivePermit = hasPermit
        ? permit
        : _WritePermit(
            accountIds: const {},
            global: true,
            blockIds: blockingIds,
            enteredMutation: true,
          );
    final future = runZoned(
      () => Future<T>.sync(operation),
      zoneValues: {this: effectivePermit},
    );
    return future.whenComplete(() {
      _activeGlobal -= 1;
      _signalStateChange();
    });
  }

  @override
  OfflineMutationBlock blockMutations(OfflineMutationScope scope) {
    final blockId = ++_nextBlockId;
    if (scope.allAccounts) {
      _globalBlocks.add(blockId);
    } else {
      for (final accountId in scope.resolvedAccountIds) {
        _accountBlocks.putIfAbsent(accountId, () => {}).add(blockId);
      }
    }
    _signalStateChange();
    return _OfflineWriteBarrierBlock(this, scope, blockId);
  }

  @override
  Future<T> runWithMutationPermit<T>({
    required OfflineMutationScope scope,
    required Set<Object> blockIds,
    required Future<T> Function() operation,
  }) {
    if (blockIds.isEmpty) return Future<T>.sync(operation);
    final permit = _WritePermit(
      accountIds: scope.resolvedAccountIds,
      global: scope.allAccounts,
      blockIds: Set<Object>.unmodifiable(blockIds),
      enteredMutation: false,
    );
    return runZoned(
      () => Future<T>.sync(operation),
      zoneValues: {this: permit},
    );
  }

  Set<Object> _blockingIdsForAccounts(Set<String> accountIds) => {
    ..._globalBlocks,
    for (final accountId in accountIds) ...?_accountBlocks[accountId],
  };

  Set<Object> _allBlockingIds() => {
    ..._globalBlocks,
    for (final blocks in _accountBlocks.values) ...blocks,
  };

  Future<void> _waitForQuiescence(OfflineMutationScope scope) async {
    while (_hasActive(scope)) {
      final changed = _stateChanged.future;
      if (!_hasActive(scope)) return;
      await changed;
    }
  }

  bool _hasActive(OfflineMutationScope scope) {
    if (_activeGlobal > 0) return true;
    if (scope.allAccounts) return _activeByAccount.isNotEmpty;
    return scope.resolvedAccountIds.any(
      (accountId) => (_activeByAccount[accountId] ?? 0) > 0,
    );
  }

  void _release(OfflineMutationScope scope, Object blockId) {
    if (scope.allAccounts) {
      _globalBlocks.remove(blockId);
    } else {
      for (final accountId in scope.resolvedAccountIds) {
        final blocks = _accountBlocks[accountId];
        blocks?.remove(blockId);
        if (blocks?.isEmpty ?? false) _accountBlocks.remove(accountId);
      }
    }
    _signalStateChange();
  }

  void _signalStateChange() {
    final changed = _stateChanged;
    _stateChanged = Completer<void>();
    if (!changed.isCompleted) changed.complete();
  }
}

final class _WritePermit {
  const _WritePermit({
    required this.accountIds,
    required this.global,
    required this.blockIds,
    required this.enteredMutation,
  });

  final Set<String> accountIds;
  final bool global;
  final Set<Object> blockIds;
  final bool enteredMutation;

  bool covers(Set<String> requested) =>
      global || requested.every(accountIds.contains);
}

final class _OfflineWriteBarrierBlock implements OfflineMutationBlock {
  _OfflineWriteBarrierBlock(this._barrier, this._scope, this.blockId);

  final OfflineWriteBarrier _barrier;
  final OfflineMutationScope _scope;
  @override
  final Object blockId;
  bool _released = false;

  @override
  Future<void> waitForQuiescence() => _barrier._waitForQuiescence(_scope);

  @override
  void release() {
    if (_released) return;
    _released = true;
    _barrier._release(_scope, blockId);
  }
}

final class WriteBarrierOfflineStore
    implements
        OfflineStore,
        ConditionalCacheRecordStorage,
        AuthSessionProjectionTransactionStorage {
  const WriteBarrierOfflineStore({
    required this.delegate,
    required this.barrier,
  });

  final OfflineStore delegate;
  final OfflineWriteBarrier barrier;

  @override
  bool get supportsAuthSessionProjectionTransactions =>
      delegate is AuthSessionProjectionTransactionStorage &&
      (delegate as AuthSessionProjectionTransactionStorage)
          .supportsAuthSessionProjectionTransactions;

  @override
  Future<void> writeCache(CacheRecord record) => barrier.protect(
    accountId: record.key.accountId,
    operation: () => delegate.writeCache(record),
  );

  @override
  Future<CacheRecord?> readCache(CacheKey key, {int? schemaVersion}) =>
      barrier.protect(
        accountId: key.accountId,
        operation: () => delegate.readCache(key, schemaVersion: schemaVersion),
      );

  @override
  Future<void> enforceCacheLimit({
    required String accountId,
    required int? warehouseId,
    required String namespace,
    required int maxRecords,
  }) => barrier.protect(
    accountId: accountId,
    operation: () => delegate.enforceCacheLimit(
      accountId: accountId,
      warehouseId: warehouseId,
      namespace: namespace,
      maxRecords: maxRecords,
    ),
  );

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) => barrier.protect(
    accountId: accountId,
    operation: () => delegate.invalidateWarehouseCache(
      accountId: accountId,
      warehouseId: warehouseId,
    ),
  );

  @override
  Future<void> deleteCacheNamespace({
    required String accountId,
    required String namespace,
  }) => barrier.protect(
    accountId: accountId,
    operation: () => delegate.deleteCacheNamespace(
      accountId: accountId,
      namespace: namespace,
    ),
  );

  @override
  Future<bool> deleteCacheRecordIfPayloadMatches({
    required CacheKey key,
    required int schemaVersion,
    required String payloadField,
    required Object? expectedValue,
  }) => barrier.protect(
    accountId: key.accountId,
    operation: () {
      final conditional = delegate is ConditionalCacheRecordStorage
          ? delegate as ConditionalCacheRecordStorage
          : null;
      if (conditional == null) return Future.value(false);
      return conditional.deleteCacheRecordIfPayloadMatches(
        key: key,
        schemaVersion: schemaVersion,
        payloadField: payloadField,
        expectedValue: expectedValue,
      );
    },
  );

  @override
  Future<bool> deleteAuthSessionProjectionIfOwned({
    required CacheKey key,
    required int schemaVersion,
    required String ownerId,
    required int attemptVersion,
  }) => barrier.protect(
    accountId: key.accountId,
    operation: () {
      final transactional = delegate is AuthSessionProjectionTransactionStorage
          ? delegate as AuthSessionProjectionTransactionStorage
          : null;
      if (transactional == null) return Future.value(false);
      return transactional.deleteAuthSessionProjectionIfOwned(
        key: key,
        schemaVersion: schemaVersion,
        ownerId: ownerId,
        attemptVersion: attemptVersion,
      );
    },
  );

  @override
  Future<bool> saveAuthSessionProjectionIfCurrent(
    CacheRecord record, {
    required String ownerId,
    required int attemptVersion,
  }) => barrier.protect(
    accountId: record.key.accountId,
    operation: () {
      final transactional = delegate is AuthSessionProjectionTransactionStorage
          ? delegate as AuthSessionProjectionTransactionStorage
          : null;
      if (transactional == null ||
          !transactional.supportsAuthSessionProjectionTransactions) {
        return Future.value(false);
      }
      return transactional.saveAuthSessionProjectionIfCurrent(
        record,
        ownerId: ownerId,
        attemptVersion: attemptVersion,
      );
    },
  );

  @override
  Future<void> saveDraft(DocumentDraft draft, {int? expectedVersion}) =>
      barrier.protect(
        accountId: draft.accountId,
        operation: () =>
            delegate.saveDraft(draft, expectedVersion: expectedVersion),
      );

  @override
  Future<List<DocumentDraft>> listDrafts(String accountId) => barrier.protect(
    accountId: accountId,
    operation: () => delegate.listDrafts(accountId),
  );

  @override
  Future<void> deleteDraft({
    required String accountId,
    required String draftId,
  }) => barrier.protect(
    accountId: accountId,
    operation: () =>
        delegate.deleteDraft(accountId: accountId, draftId: draftId),
  );

  @override
  Future<void> pruneDrafts(DateTime updatedBefore) =>
      barrier.protectAll(() => delegate.pruneDrafts(updatedBefore));

  @override
  Future<void> enqueue(OutboxOperation operation, Set<String> dependencies) =>
      barrier.protect(
        accountId: operation.accountId,
        operation: () => delegate.enqueue(operation, dependencies),
      );

  @override
  Future<List<OutboxOperation>> readyOperations(String accountId) =>
      barrier.protect(
        accountId: accountId,
        operation: () => delegate.readyOperations(accountId),
      );

  @override
  Future<void> transition(
    String operationId,
    OutboxState next, {
    Failure? failure,
  }) => barrier.protectAll(
    () => delegate.transition(operationId, next, failure: failure),
  );

  @override
  Future<void> clearAccount(String accountId) => barrier.protect(
    accountId: accountId,
    operation: () => delegate.clearAccount(accountId),
  );

  @override
  Future<void> prune(DateTime now) =>
      barrier.protectAll(() => delegate.prune(now));
}

final class WriteBarrierOutboxRepository implements OutboxRepository {
  const WriteBarrierOutboxRepository({
    required this.delegate,
    required this.barrier,
  });

  final OutboxRepository delegate;
  final OfflineWriteBarrier barrier;

  Future<Result<T>> _write<T>(
    String accountId,
    Future<Result<T>> Function() operation,
  ) async {
    try {
      return await barrier.protect(accountId: accountId, operation: operation);
    } on OfflineWriteBlockedException catch (error) {
      return FailureResult(
        StateFailure(
          message: 'Offline writes are temporarily blocked.',
          cause: error,
        ),
      );
    }
  }

  Future<Result<T>> _read<T>(
    String accountId,
    Future<Result<T>> Function() operation,
  ) => _write(accountId, operation);

  @override
  Future<Result<List<OutboxOperation>>> enqueueGraph(OutboxGraph graph) async {
    final accountIds = graph.operations.map((value) => value.accountId).toSet();
    if (accountIds.isEmpty) return delegate.enqueueGraph(graph);
    try {
      return await barrier.protectAccounts(
        accountIds: accountIds,
        operation: () => delegate.enqueueGraph(graph),
      );
    } on OfflineWriteBlockedException catch (error) {
      return FailureResult(
        StateFailure(
          message: 'Offline writes are temporarily blocked.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  }) => _write(
    operation.accountId,
    () => delegate.enqueue(operation, dependencies: dependencies),
  );

  @override
  Future<Result<List<OutboxOperation>>> list(String accountId) =>
      _read(accountId, () => delegate.list(accountId));

  @override
  Future<Result<List<OutboxOperation>>> loadConnectedComponent({
    required String accountId,
    required Set<String> operationIds,
  }) => _read(
    accountId,
    () => delegate.loadConnectedComponent(
      accountId: accountId,
      operationIds: operationIds,
    ),
  );

  @override
  Future<Result<List<OutboxOperation>>> ready(
    String accountId, {
    String? reviewStamp,
  }) => _read(
    accountId,
    () => delegate.ready(accountId, reviewStamp: reviewStamp),
  );

  @override
  Future<Result<OutboxOperation>> confirm({
    required String accountId,
    required String operationId,
    String? reviewStamp,
    DateTime? expectedUpdatedAt,
  }) => _write(
    accountId,
    () => delegate.confirm(
      accountId: accountId,
      operationId: operationId,
      reviewStamp: reviewStamp,
      expectedUpdatedAt: expectedUpdatedAt,
    ),
  );

  @override
  Future<Result<List<OutboxOperation>>> invalidateReviewGraph({
    required String accountId,
    required Map<String, DateTime> expectedUpdatedAtByOperation,
  }) => _write(
    accountId,
    () => delegate.invalidateReviewGraph(
      accountId: accountId,
      expectedUpdatedAtByOperation: expectedUpdatedAtByOperation,
    ),
  );

  @override
  Future<Result<int>> recoverStaleSyncing({
    required String accountId,
    required DateTime staleBefore,
    required Set<String> operationIds,
  }) => _write(
    accountId,
    () => delegate.recoverStaleSyncing(
      accountId: accountId,
      staleBefore: staleBefore,
      operationIds: operationIds,
    ),
  );

  @override
  Future<Result<OutboxOperation>> retryNow({
    required String accountId,
    required String operationId,
  }) => _write(
    accountId,
    () => delegate.retryNow(accountId: accountId, operationId: operationId),
  );

  @override
  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  }) => _write(
    accountId,
    () => delegate.transition(
      accountId: accountId,
      operationId: operationId,
      next: next,
      failure: failure,
    ),
  );

  @override
  Future<Result<OutboxOperation>> completeSuccess({
    required String accountId,
    required String operationId,
    required OutboxOperationOutput output,
    OutboxCleanupRequest? cleanup,
  }) => _write(
    accountId,
    () => delegate.completeSuccess(
      accountId: accountId,
      operationId: operationId,
      output: output,
      cleanup: cleanup,
    ),
  );

  @override
  Future<Result<Map<String, OutboxOperationOutput>>> loadDependencyOutputs({
    required String accountId,
    required String operationId,
  }) => _read(
    accountId,
    () => delegate.loadDependencyOutputs(
      accountId: accountId,
      operationId: operationId,
    ),
  );

  @override
  Future<Result<List<OutboxCleanupIntent>>> listCleanupIntents(
    String accountId,
  ) => _read(accountId, () => delegate.listCleanupIntents(accountId));

  @override
  Future<Result<void>> recordCleanupFailure({
    required String accountId,
    required String operationId,
    required String failure,
  }) => _write(
    accountId,
    () => delegate.recordCleanupFailure(
      accountId: accountId,
      operationId: operationId,
      failure: failure,
    ),
  );

  @override
  Future<Result<void>> completeCleanupIntent({
    required String accountId,
    required String operationId,
  }) => _write(
    accountId,
    () => delegate.completeCleanupIntent(
      accountId: accountId,
      operationId: operationId,
    ),
  );

  @override
  Future<Result<OutboxOperation>> cancel({
    required String accountId,
    required String operationId,
  }) => _write(
    accountId,
    () => delegate.cancel(accountId: accountId, operationId: operationId),
  );

  @override
  Future<Result<OutboxOperation>> discard({
    required String accountId,
    required String operationId,
  }) => _write(
    accountId,
    () => delegate.discard(accountId: accountId, operationId: operationId),
  );

  @override
  Future<Result<OutboxOperation>> resolveConflict({
    required String accountId,
    required String conflictedOperationId,
    required OutboxOperation replacement,
    Set<String> dependencies = const {},
  }) => _write(
    accountId,
    () => delegate.resolveConflict(
      accountId: accountId,
      conflictedOperationId: conflictedOperationId,
      replacement: replacement,
      dependencies: dependencies,
    ),
  );

  @override
  Future<Result<void>> clearAccount(String accountId) =>
      _write(accountId, () => delegate.clearAccount(accountId));

  @override
  Future<Result<int>> prune({required String accountId}) =>
      _write(accountId, () => delegate.prune(accountId: accountId));
}
