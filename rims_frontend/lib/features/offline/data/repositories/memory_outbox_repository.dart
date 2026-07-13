import 'dart:convert';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/outbox_state_machine.dart';
import '../models/cache_record_model.dart';

final class MemoryOutboxRepository implements OutboxRepository {
  MemoryOutboxRepository({
    required this.stateMachine,
    DateTime Function()? now,
    this.succeededRetention = const Duration(days: 7),
    this.failedRetention = const Duration(days: 30),
  }) : now = now ?? DateTime.now;

  static const int maxOperationsPerAccount = 500;

  final OutboxStateMachine stateMachine;
  final DateTime Function() now;
  final Duration succeededRetention;
  final Duration failedRetention;
  final Map<String, OutboxOperation> _operations = {};
  final Map<String, Set<String>> _dependencies = {};
  final Map<String, String> _replacementByOriginal = {};
  final Map<String, String> _payloadFingerprintByOperation = {};

  @override
  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  }) async {
    final failure = _validateEnqueue(operation, dependencies);
    if (failure != null) return FailureResult(failure);
    final payloadJson = _serializePayload(operation.payload);
    _operations[operation.operationId] = operation;
    _dependencies[operation.operationId] = Set.unmodifiable(dependencies);
    _payloadFingerprintByOperation[operation.operationId] = payloadJson;
    return Success(operation);
  }

  @override
  Future<Result<List<OutboxOperation>>> list(String accountId) async {
    final operations =
        _operations.values
            .where((operation) => operation.accountId == accountId)
            .toList()
          ..sort(_compareOperations);
    return Success(List.unmodifiable(operations));
  }

  @override
  Future<Result<List<OutboxOperation>>> ready(
    String accountId, {
    String? reviewStamp,
  }) async {
    final currentTime = now().toUtc();
    final operations = _operations.values.where((operation) {
      if (operation.accountId != accountId ||
          !operation.isConfirmed ||
          (reviewStamp != null && operation.reviewStamp != reviewStamp) ||
          (operation.state != OutboxState.queued &&
              operation.state != OutboxState.retryableFailure) ||
          (operation.nextAttemptAt?.isAfter(currentTime) ?? false)) {
        return false;
      }
      return (_dependencies[operation.operationId] ?? const <String>{}).every(
        (dependency) => _operations[dependency]?.state == OutboxState.succeeded,
      );
    }).toList()..sort(_compareOperations);
    return Success(List.unmodifiable(operations));
  }

  @override
  Future<Result<OutboxOperation>> confirm({
    required String accountId,
    required String operationId,
    String? reviewStamp,
    DateTime? expectedUpdatedAt,
  }) async {
    final operation = _operations[operationId];
    if (operation == null || operation.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    if (operation.state != OutboxState.queued &&
        operation.state != OutboxState.retryableFailure) {
      return const FailureResult(
        StateFailure(message: 'Only waiting offline work can be reviewed.'),
      );
    }
    if (expectedUpdatedAt != null &&
        operation.updatedAt.toUtc() != expectedUpdatedAt.toUtc()) {
      return const FailureResult(
        ConflictFailure(message: 'Offline review context changed.'),
      );
    }
    if (operation.reviewStamp != null &&
        reviewStamp != null &&
        operation.reviewStamp != reviewStamp) {
      return const FailureResult(
        ConflictFailure(message: 'Offline review context changed.'),
      );
    }
    final confirmedAt = now().toUtc();
    final confirmed = operation.copyWith(
      confirmedAt: confirmedAt,
      updatedAt: confirmedAt,
      reviewStamp: reviewStamp,
    );
    _operations[operationId] = confirmed;
    return Success(confirmed);
  }

  @override
  Future<Result<int>> recoverStaleSyncing({
    required String accountId,
    required DateTime staleBefore,
    required Set<String> operationIds,
  }) async {
    var count = 0;
    final recoveredAt = now().toUtc();
    for (final entry in _operations.entries.toList(growable: false)) {
      final operation = entry.value;
      final startedAt = operation.syncingStartedAt;
      if (operation.accountId != accountId ||
          !operationIds.contains(operation.operationId) ||
          operation.state != OutboxState.syncing ||
          startedAt == null ||
          startedAt.isAfter(staleBefore.toUtc())) {
        continue;
      }
      _operations[entry.key] = operation.copyWith(
        state: OutboxState.retryableFailure,
        updatedAt: recoveredAt,
        nextAttemptAt: recoveredAt,
        attemptCount: operation.attemptCount + 1,
        lastFailureCode: 'unknown_result',
        requiresStatusProbe: true,
        clearSyncingStartedAt: true,
      );
      count += 1;
    }
    return Success(count);
  }

  @override
  Future<Result<OutboxOperation>> retryNow({
    required String accountId,
    required String operationId,
  }) async {
    final operation = _operations[operationId];
    if (operation == null || operation.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    if (operation.state == OutboxState.queued) return Success(operation);
    if (operation.state != OutboxState.retryableFailure) {
      return const FailureResult(
        StateFailure(message: 'Only retryable offline work can retry now.'),
      );
    }
    final ready = operation.copyWith(
      updatedAt: now().toUtc(),
      clearNextAttemptAt: true,
    );
    _operations[operationId] = ready;
    return Success(ready);
  }

  @override
  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  }) async {
    final current = _operations[operationId];
    if (current == null || current.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    if (_isTerminal(current.state) && _isTerminal(next)) {
      return const FailureResult(
        ConflictFailure(
          message: 'Offline operation already reached a terminal state.',
        ),
      );
    }
    final result = stateMachine.transition(current, next, failure: failure);
    if (result case FailureResult<OutboxOperation>()) return result;
    if (!identical(_operations[operationId], current)) {
      return const FailureResult(
        ConflictFailure(
          message: 'Offline operation state changed concurrently.',
        ),
      );
    }
    final updated = (result as Success<OutboxOperation>).data;
    _operations[operationId] = updated;
    if (_blocksDependencies(next)) {
      _cancelDescendants(accountId, operationId, updated.updatedAt);
    }
    return Success(updated);
  }

  @override
  Future<Result<OutboxOperation>> cancel({
    required String accountId,
    required String operationId,
  }) {
    return transition(
      accountId: accountId,
      operationId: operationId,
      next: OutboxState.cancelled,
      failure: const CancellationFailure(),
    );
  }

  @override
  Future<Result<OutboxOperation>> discard({
    required String accountId,
    required String operationId,
  }) async {
    final operation = _operations[operationId];
    if (operation == null || operation.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    if (!_isTerminal(operation.state)) {
      return const FailureResult(
        StateFailure(message: 'Only completed offline work can be discarded.'),
      );
    }
    final hasDependent = _dependencies.entries.any(
      (entry) =>
          entry.value.contains(operationId) &&
          _operations[entry.key]?.accountId == accountId,
    );
    if (hasDependent) {
      return const FailureResult(
        StateFailure(
          message: 'Offline work with dependents cannot be discarded.',
        ),
      );
    }
    _operations.remove(operationId);
    _dependencies.remove(operationId);
    _payloadFingerprintByOperation.remove(operationId);
    _replacementByOriginal.removeWhere(
      (original, replacement) =>
          original == operationId || replacement == operationId,
    );
    return Success(operation);
  }

  @override
  Future<Result<OutboxOperation>> resolveConflict({
    required String accountId,
    required String conflictedOperationId,
    required OutboxOperation replacement,
    Set<String> dependencies = const {},
  }) async {
    if (replacement.replacementOf != null ||
        replacement.state != OutboxState.queued ||
        replacement.accountId != accountId) {
      return const FailureResult(
        ValidationFailure(
          message: 'Conflict replacement must be a new queued operation.',
        ),
      );
    }
    final payloadJson = _serializePayload(replacement.payload);
    final dependencyFingerprint = _dependencyFingerprint(dependencies);
    final existingId = _replacementByOriginal[conflictedOperationId];
    final existing = existingId == null ? null : _operations[existingId];
    final claimed = replacement.copyWith(replacementOf: conflictedOperationId);
    if (existing != null) {
      return _replayOrConflict(
        existing,
        claimed,
        payloadJson,
        _dependencyFingerprint(
          _dependencies[existing.operationId] ?? const <String>{},
        ),
        dependencyFingerprint,
      );
    }

    final original = _operations[conflictedOperationId];
    if (original == null ||
        original.accountId != accountId ||
        original.state != OutboxState.conflict) {
      return const FailureResult(
        StateFailure(message: 'Only a conflicted operation can be resolved.'),
      );
    }
    if (replacement.accountId != accountId ||
        replacement.operationId == original.operationId ||
        replacement.idempotencyKey == original.idempotencyKey ||
        replacement.warehouseId != original.warehouseId ||
        replacement.kind != original.kind) {
      return const FailureResult(
        ValidationFailure(
          message: 'Conflict resolution requires a new operation and key.',
        ),
      );
    }
    final validation = _validateEnqueue(
      claimed,
      dependencies,
      allowReplacement: true,
    );
    if (validation != null) return FailureResult(validation);
    _operations[claimed.operationId] = claimed;
    _dependencies[claimed.operationId] = Set.unmodifiable(dependencies);
    _payloadFingerprintByOperation[claimed.operationId] = payloadJson;
    _replacementByOriginal[conflictedOperationId] = claimed.operationId;
    return Success(claimed);
  }

  @override
  Future<Result<void>> clearAccount(String accountId) async {
    final operationIds = _operations.values
        .where((operation) => operation.accountId == accountId)
        .map((operation) => operation.operationId)
        .toSet();
    _replacementByOriginal.removeWhere(
      (originalId, replacementId) =>
          operationIds.contains(originalId) ||
          operationIds.contains(replacementId),
    );
    _operations.removeWhere((operationId, _) {
      if (!operationIds.contains(operationId)) return false;
      _payloadFingerprintByOperation.remove(operationId);
      return true;
    });
    _dependencies.removeWhere(
      (operationId, parents) =>
          operationIds.contains(operationId) ||
          parents.any(operationIds.contains),
    );
    return const Success<void>(null);
  }

  @override
  Future<Result<int>> prune({required String accountId}) async {
    final currentTime = now().toUtc();
    final accountOperations = {
      for (final operation in _operations.values)
        if (operation.accountId == accountId) operation.operationId: operation,
    };
    final children = {
      for (final operationId in accountOperations.keys) operationId: <String>{},
    };
    for (final entry in _dependencies.entries) {
      if (!accountOperations.containsKey(entry.key)) continue;
      for (final dependency in entry.value) {
        if (accountOperations.containsKey(dependency)) {
          children[dependency]!.add(entry.key);
        }
      }
    }
    final expiredIds = <String>{};
    for (final operation in accountOperations.values) {
      if (!_isExpiredTerminal(operation, currentTime)) continue;
      if (operation.state != OutboxState.succeeded &&
          _hasActiveDescendant(operation.operationId, children)) {
        continue;
      }
      expiredIds.add(operation.operationId);
    }
    final removableResolutionOriginalIds = <String>{};
    for (final entry in _replacementByOriginal.entries) {
      final originalExpired = expiredIds.contains(entry.key);
      final replacementExpired = expiredIds.contains(entry.value);
      if (originalExpired && replacementExpired) {
        removableResolutionOriginalIds.add(entry.key);
      } else if (originalExpired || replacementExpired) {
        expiredIds
          ..remove(entry.key)
          ..remove(entry.value);
      }
    }
    for (final originalId in removableResolutionOriginalIds) {
      _replacementByOriginal.remove(originalId);
    }
    for (final operationId in expiredIds) {
      _operations.remove(operationId);
      _dependencies.remove(operationId);
      _payloadFingerprintByOperation.remove(operationId);
    }
    _dependencies.updateAll(
      (_, dependencies) => Set.unmodifiable(
        dependencies.where((dependency) => !expiredIds.contains(dependency)),
      ),
    );
    return Success(expiredIds.length);
  }

  Failure? _validateEnqueue(
    OutboxOperation operation,
    Set<String> dependencies, {
    bool allowReplacement = false,
  }) {
    if (operation.state != OutboxState.queued &&
        operation.state != OutboxState.retryableFailure) {
      return const ValidationFailure(
        message: 'New outbox operations must be pending.',
      );
    }
    if (!allowReplacement && operation.replacementOf != null) {
      return const ValidationFailure(
        message: 'Replacement ownership can only be created by resolution.',
      );
    }
    if (dependencies.contains(operation.operationId)) {
      return const ValidationFailure(
        message: 'An operation cannot depend on itself.',
      );
    }
    final activeCount = _operations.values
        .where(
          (candidate) =>
              candidate.accountId == operation.accountId &&
              _isActive(candidate.state),
        )
        .length;
    if (activeCount >= maxOperationsPerAccount) {
      return const StateFailure(
        message: 'The offline outbox limit is 500 operations.',
      );
    }
    if (_operations.containsKey(operation.operationId) ||
        _operations.values.any(
          (candidate) =>
              candidate.accountId == operation.accountId &&
              candidate.idempotencyKey == operation.idempotencyKey,
        )) {
      return const ValidationFailure(
        message: 'The operation id or idempotency key already exists.',
      );
    }
    for (final dependency in dependencies) {
      final parent = _operations[dependency];
      if (parent == null || parent.accountId != operation.accountId) {
        return const ValidationFailure(
          message: 'Dependencies must exist in the same account.',
        );
      }
      if (_hasAncestor(dependency, operation.operationId)) {
        return const ValidationFailure(
          message: 'The dependency graph cannot contain a cycle.',
        );
      }
    }
    return null;
  }

  bool _hasAncestor(String operationId, String target) {
    final visited = <String>{};
    final pending = <String>[operationId];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current)) continue;
      for (final parent in _dependencies[current] ?? const <String>{}) {
        if (parent == target) return true;
        pending.add(parent);
      }
    }
    return false;
  }

  void _cancelDescendants(
    String accountId,
    String operationId,
    DateTime transitionedAt,
  ) {
    final pending = <String>[operationId];
    final visited = <String>{operationId};
    while (pending.isNotEmpty) {
      final parent = pending.removeLast();
      for (final entry in _dependencies.entries) {
        if (!entry.value.contains(parent) || !visited.add(entry.key)) continue;
        pending.add(entry.key);
        final operation = _operations[entry.key];
        if (operation == null ||
            operation.accountId != accountId ||
            !_isPending(operation.state)) {
          continue;
        }
        _operations[entry.key] = operation.copyWith(
          state: OutboxState.cancelled,
          updatedAt: transitionedAt,
          clearNextAttemptAt: true,
          lastFailureCode: 'dependency_failed',
        );
      }
    }
  }

  bool _hasActiveDescendant(
    String operationId,
    Map<String, Set<String>> children,
  ) {
    final pending = <String>[...children[operationId] ?? const <String>{}];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final childId = pending.removeLast();
      if (!visited.add(childId)) continue;
      final child = _operations[childId];
      if (child != null && _isActive(child.state)) return true;
      pending.addAll(children[childId] ?? const <String>{});
    }
    return false;
  }

  Result<OutboxOperation> _replayOrConflict(
    OutboxOperation existing,
    OutboxOperation requested,
    String requestedPayloadJson,
    String storedDependencyFingerprint,
    String requestedDependencyFingerprint,
  ) {
    if (existing.operationId == requested.operationId &&
        existing.idempotencyKey == requested.idempotencyKey &&
        existing.kind == requested.kind &&
        existing.warehouseId == requested.warehouseId &&
        _payloadFingerprintByOperation[existing.operationId] ==
            requestedPayloadJson &&
        storedDependencyFingerprint == requestedDependencyFingerprint) {
      return Success(existing);
    }
    return const FailureResult(
      ConflictFailure(
        message: 'The conflicted operation already has a replacement.',
      ),
    );
  }

  bool _isExpiredTerminal(OutboxOperation operation, DateTime currentTime) {
    return switch (operation.state) {
      OutboxState.succeeded => operation.updatedAt.isBefore(
        currentTime.subtract(succeededRetention),
      ),
      OutboxState.conflict ||
      OutboxState.permanentFailure ||
      OutboxState.cancelled => operation.updatedAt.isBefore(
        currentTime.subtract(failedRetention),
      ),
      OutboxState.queued ||
      OutboxState.syncing ||
      OutboxState.retryableFailure => false,
    };
  }
}

int _compareOperations(OutboxOperation left, OutboxOperation right) {
  final byTime = left.createdAt.compareTo(right.createdAt);
  return byTime != 0 ? byTime : left.operationId.compareTo(right.operationId);
}

bool _isActive(OutboxState state) =>
    state == OutboxState.queued ||
    state == OutboxState.syncing ||
    state == OutboxState.retryableFailure;

bool _isPending(OutboxState state) =>
    state == OutboxState.queued || state == OutboxState.retryableFailure;

bool _blocksDependencies(OutboxState state) =>
    state == OutboxState.conflict ||
    state == OutboxState.permanentFailure ||
    state == OutboxState.cancelled;

String _dependencyFingerprint(Set<String> dependencies) {
  final sorted = dependencies.toList()..sort();
  return sorted.join('\u0000');
}

String _serializePayload(Map<String, Object?> payload) {
  try {
    return CacheRecordModel.canonicalJson(payload);
  } on JsonUnsupportedObjectError catch (error) {
    final cause = error.cause;
    if (cause is StateError) throw cause;
    rethrow;
  }
}

bool _isTerminal(OutboxState state) => switch (state) {
  OutboxState.succeeded ||
  OutboxState.conflict ||
  OutboxState.permanentFailure ||
  OutboxState.cancelled => true,
  OutboxState.queued ||
  OutboxState.syncing ||
  OutboxState.retryableFailure => false,
};
