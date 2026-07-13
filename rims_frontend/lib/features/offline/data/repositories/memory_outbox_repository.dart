import 'dart:convert';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/entities/outbox_graph.dart';
import '../../domain/entities/outbox_cleanup_intent.dart';
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
  final Map<String, OutboxCleanupIntent> _cleanupIntents = {};

  @override
  Future<Result<List<OutboxOperation>>> enqueueGraph(OutboxGraph graph) async {
    if (graph.operations.isEmpty) {
      return const FailureResult(
        ValidationFailure(message: 'An outbox graph cannot be empty.'),
      );
    }

    final requestedById = <String, OutboxOperation>{};
    final requestedKeys = <String>{};
    final payloads = <String, String>{};
    final accountId = graph.operations.first.accountId;
    final warehouseId = graph.operations.first.warehouseId;
    for (final operation in graph.operations) {
      if (operation.accountId != accountId ||
          operation.warehouseId != warehouseId ||
          operation.state != OutboxState.queued ||
          operation.replacementOf != null ||
          operation.operationId.isEmpty ||
          operation.idempotencyKey.isEmpty ||
          requestedById.containsKey(operation.operationId) ||
          !requestedKeys.add(operation.idempotencyKey)) {
        return const FailureResult(
          ValidationFailure(message: 'The outbox graph is invalid.'),
        );
      }
      requestedById[operation.operationId] = operation;
      payloads[operation.operationId] = _serializePayload(operation.payload);
    }
    if (graph.dependencies.keys.any((id) => !requestedById.containsKey(id)) ||
        graph.dependencies.entries.any(
          (entry) => entry.value.contains(entry.key),
        )) {
      return const FailureResult(
        ValidationFailure(message: 'The outbox dependency graph is invalid.'),
      );
    }

    final existing = graph.operations
        .map((operation) => _operations[operation.operationId])
        .whereType<OutboxOperation>()
        .toList(growable: false);
    if (existing.isNotEmpty) {
      if (existing.length != graph.operations.length ||
          !_isExactGraphReplay(graph, payloads)) {
        return const FailureResult(
          ConflictFailure(message: 'The outbox graph already exists.'),
        );
      }
      return Success(List.unmodifiable(existing));
    }

    final activeCount = _operations.values
        .where(
          (operation) =>
              operation.accountId == accountId && _isActive(operation.state),
        )
        .length;
    if (activeCount + graph.operations.length > maxOperationsPerAccount) {
      return const FailureResult(
        StateFailure(message: 'The offline outbox limit is 500 operations.'),
      );
    }
    if (_operations.values.any(
      (stored) =>
          stored.accountId == accountId &&
          requestedKeys.contains(stored.idempotencyKey),
    )) {
      return const FailureResult(
        ConflictFailure(message: 'An idempotency key already exists.'),
      );
    }
    for (final entry in graph.dependencies.entries) {
      for (final dependencyId in entry.value) {
        final dependency =
            requestedById[dependencyId] ?? _operations[dependencyId];
        if (dependency == null || dependency.accountId != accountId) {
          return const FailureResult(
            ValidationFailure(
              message: 'Dependencies must exist in the same account.',
            ),
          );
        }
      }
    }
    if (_graphHasCycle(graph, requestedById.keys.toSet())) {
      return const FailureResult(
        ValidationFailure(
          message: 'The dependency graph cannot contain a cycle.',
        ),
      );
    }

    final nextOperations = Map<String, OutboxOperation>.of(_operations);
    final nextDependencies = <String, Set<String>>{
      for (final entry in _dependencies.entries) entry.key: entry.value,
    };
    final nextFingerprints = Map<String, String>.of(
      _payloadFingerprintByOperation,
    );
    for (final operation in graph.operations) {
      nextOperations[operation.operationId] = operation;
      nextDependencies[operation.operationId] = Set.unmodifiable(
        graph.dependencies[operation.operationId] ?? const <String>{},
      );
      nextFingerprints[operation.operationId] =
          payloads[operation.operationId]!;
    }
    _operations
      ..clear()
      ..addAll(nextOperations);
    _dependencies
      ..clear()
      ..addAll(nextDependencies);
    _payloadFingerprintByOperation
      ..clear()
      ..addAll(nextFingerprints);
    return Success(List.unmodifiable(graph.operations));
  }

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
  Future<Result<List<OutboxOperation>>> loadConnectedComponent({
    required String accountId,
    required Set<String> operationIds,
  }) async {
    final accountOperations = {
      for (final operation in _operations.values)
        if (operation.accountId == accountId) operation.operationId: operation,
    };
    final connectedIds = _connectedOperationIds(
      accountOperations.keys.toSet(),
      _dependencies,
      operationIds,
    );
    final operations =
        connectedIds
            .map((operationId) => accountOperations[operationId]!)
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
    final confirmedAt = _nextReviewTimestamp(now(), operation.updatedAt);
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
  Future<Result<OutboxOperation>> completeSuccess({
    required String accountId,
    required String operationId,
    required OutboxOperationOutput output,
    OutboxCleanupRequest? cleanup,
  }) async {
    final current = _operations[operationId];
    if (current == null || current.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    if (current.state != OutboxState.syncing || output.version <= 0) {
      return const FailureResult(
        StateFailure(message: 'Only syncing work can complete successfully.'),
      );
    }
    _serializePayload(output.data);
    final transition = stateMachine.transition(current, OutboxState.succeeded);
    if (transition case FailureResult<OutboxOperation>()) return transition;
    final completed = (transition as Success<OutboxOperation>).data.copyWith(
      output: OutboxOperationOutput(
        version: output.version,
        data: Map.unmodifiable(output.data),
      ),
    );
    final timestamp = completed.updatedAt;
    OutboxCleanupIntent? intent;
    if (cleanup != null) {
      intent = OutboxCleanupIntent(
        operationId: operationId,
        accountId: accountId,
        warehouseId: current.warehouseId,
        draftId: cleanup.draftId,
        attachmentRequestIds: cleanup.attachmentRequestIds,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
    }
    _operations[operationId] = completed;
    if (intent != null) _cleanupIntents[operationId] = intent;
    return Success(completed);
  }

  @override
  Future<Result<Map<String, OutboxOperationOutput>>> loadDependencyOutputs({
    required String accountId,
    required String operationId,
  }) async {
    final operation = _operations[operationId];
    if (operation == null || operation.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    final outputs = <String, OutboxOperationOutput>{};
    for (final dependencyId in _dependencies[operationId] ?? const <String>{}) {
      final dependency = _operations[dependencyId];
      if (dependency?.output case final output?) outputs[dependencyId] = output;
    }
    return Success(Map.unmodifiable(outputs));
  }

  @override
  Future<Result<List<OutboxCleanupIntent>>> listCleanupIntents(
    String accountId,
  ) async {
    final intents =
        _cleanupIntents.values
            .where((intent) => intent.accountId == accountId)
            .toList()
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return Success(List.unmodifiable(intents));
  }

  @override
  Future<Result<void>> recordCleanupFailure({
    required String accountId,
    required String operationId,
    required String failure,
  }) async {
    final current = _cleanupIntents[operationId];
    if (current == null || current.accountId != accountId) {
      return const FailureResult(
        NotFoundFailure(message: 'Cleanup intent not found.'),
      );
    }
    _cleanupIntents[operationId] = OutboxCleanupIntent(
      operationId: current.operationId,
      accountId: current.accountId,
      warehouseId: current.warehouseId,
      draftId: current.draftId,
      attachmentRequestIds: current.attachmentRequestIds,
      createdAt: current.createdAt,
      updatedAt: now().toUtc(),
      attemptCount: current.attemptCount + 1,
      lastFailure: failure,
    );
    return const Success(null);
  }

  @override
  Future<Result<void>> completeCleanupIntent({
    required String accountId,
    required String operationId,
  }) async {
    final current = _cleanupIntents[operationId];
    if (current != null && current.accountId != accountId) {
      return const FailureResult(
        AuthorizationFailure(
          message: 'Cleanup intent belongs to another account.',
        ),
      );
    }
    _cleanupIntents.remove(operationId);
    return const Success(null);
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
    _cleanupIntents.removeWhere((_, intent) => intent.accountId == accountId);
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
      if (_cleanupIntents.containsKey(operation.operationId)) continue;
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

  bool _isExactGraphReplay(OutboxGraph graph, Map<String, String> payloads) {
    for (final requested in graph.operations) {
      final stored = _operations[requested.operationId];
      if (stored == null ||
          stored.accountId != requested.accountId ||
          stored.warehouseId != requested.warehouseId ||
          stored.kind != requested.kind ||
          stored.idempotencyKey != requested.idempotencyKey ||
          _payloadFingerprintByOperation[requested.operationId] !=
              payloads[requested.operationId] ||
          _dependencyFingerprint(
                _dependencies[requested.operationId] ?? const <String>{},
              ) !=
              _dependencyFingerprint(
                graph.dependencies[requested.operationId] ?? const <String>{},
              )) {
        return false;
      }
    }
    return true;
  }

  bool _graphHasCycle(OutboxGraph graph, Set<String> graphIds) {
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String id) {
      if (visiting.contains(id)) return true;
      if (!graphIds.contains(id) || visited.contains(id)) return false;
      visiting.add(id);
      for (final dependency in graph.dependencies[id] ?? const <String>{}) {
        if (visit(dependency)) return true;
      }
      visiting.remove(id);
      visited.add(id);
      return false;
    }

    return graphIds.any(visit);
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

Set<String> _connectedOperationIds(
  Set<String> accountOperationIds,
  Map<String, Set<String>> dependencies,
  Set<String> requestedIds,
) {
  final connected = <String>{};
  final pending = requestedIds.where(accountOperationIds.contains).toList();
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!connected.add(current)) continue;
    pending.addAll(
      (dependencies[current] ?? const <String>{}).where(
        accountOperationIds.contains,
      ),
    );
    for (final entry in dependencies.entries) {
      if (entry.value.contains(current) &&
          accountOperationIds.contains(entry.key)) {
        pending.add(entry.key);
      }
    }
  }
  return connected;
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

DateTime _nextReviewTimestamp(DateTime now, DateTime current) {
  final candidate = now.toUtc();
  final minimum = current.toUtc().add(const Duration(seconds: 1));
  return candidate.isAfter(minimum) ? candidate : minimum;
}
