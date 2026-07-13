import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/outbox_state_machine.dart';
import '../database/offline_database.dart';
import '../models/cache_record_model.dart';

final class DriftOutboxRepository implements OutboxRepository {
  DriftOutboxRepository({
    required this.database,
    required this.stateMachine,
    DateTime Function()? now,
    this.succeededRetention = const Duration(days: 7),
    this.failedRetention = const Duration(days: 30),
  }) : now = now ?? DateTime.now;

  static const int maxOperationsPerAccount = 500;

  final OfflineDatabase database;
  final OutboxStateMachine stateMachine;
  final DateTime Function() now;
  final Duration succeededRetention;
  final Duration failedRetention;

  @override
  Future<Result<OutboxOperation>> enqueue(
    OutboxOperation operation, {
    Set<String> dependencies = const {},
  }) async {
    if (operation.state != OutboxState.queued &&
        operation.state != OutboxState.retryableFailure) {
      return const FailureResult(
        ValidationFailure(message: 'New outbox operations must be pending.'),
      );
    }
    if (operation.replacementOf != null) {
      return const FailureResult(
        ValidationFailure(
          message: 'Replacement ownership can only be created by resolution.',
        ),
      );
    }
    if (dependencies.contains(operation.operationId)) {
      return const FailureResult(
        ValidationFailure(message: 'An operation cannot depend on itself.'),
      );
    }

    final payloadJson = _serializePayload(operation.payload);
    try {
      await database.transaction(() async {
        await _validateCapacity(operation.accountId);
        await _validateIdentity(operation);
        await _validateDependencies(operation, dependencies);
        await _insertOperation(operation, dependencies, payloadJson);
      });
      return Success(operation);
    } on _OutboxValidationException catch (error) {
      return FailureResult(ValidationFailure(message: error.message));
    } on _OutboxCapacityException catch (error) {
      return FailureResult(StateFailure(message: error.message));
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to enqueue offline operation.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to enqueue offline operation.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<OutboxOperation>>> list(String accountId) async {
    try {
      final query = database.select(database.offlineOutboxOperations)
        ..where((row) => row.accountId.equals(accountId))
        ..orderBy([
          (row) => OrderingTerm.asc(row.createdAt),
          (row) => OrderingTerm.asc(row.operationId),
        ]);
      return Success(
        List.unmodifiable((await query.get()).map(_toDomainOperation)),
      );
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operations.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operations.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<OutboxOperation>>> ready(String accountId) async {
    final currentTime = now().toUtc();
    try {
      final rows = await database
          .customSelect(
            '''
SELECT operation.*
FROM outbox_operations AS operation
WHERE operation.account_id = ?
  AND operation.confirmed_at IS NOT NULL
  AND operation.operation_state IN (?, ?)
  AND (operation.next_attempt_at IS NULL OR operation.next_attempt_at <= ?)
  AND NOT EXISTS (
    SELECT 1
    FROM outbox_dependencies AS edge
    JOIN outbox_operations AS parent
      ON parent.operation_id = edge.dependency_id
    WHERE edge.operation_id = operation.operation_id
      AND parent.operation_state <> ?
  )
ORDER BY operation.created_at ASC, operation.operation_id ASC
''',
            variables: [
              Variable(accountId),
              Variable(OutboxState.queued.wireValue),
              Variable(OutboxState.retryableFailure.wireValue),
              Variable(currentTime),
              Variable(OutboxState.succeeded.wireValue),
            ],
            readsFrom: {
              database.offlineOutboxOperations,
              database.offlineOutboxDependencies,
            },
          )
          .get();
      return Success(
        List.unmodifiable(
          rows.map(
            (row) => _toDomainOperation(
              database.offlineOutboxOperations.map(row.data),
            ),
          ),
        ),
      );
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to determine ready offline operations.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to determine ready offline operations.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<OutboxOperation>> transition({
    required String accountId,
    required String operationId,
    required OutboxState next,
    Failure? failure,
  }) async {
    late final OfflineOutboxOperation? row;
    late final OutboxOperation? current;
    try {
      row = await _find(accountId, operationId);
      current = row == null ? null : _toDomainOperation(row);
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operation state.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operation state.',
          cause: error,
        ),
      );
    }
    if (current == null) {
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
    final updated = (result as Success<OutboxOperation>).data;

    try {
      return await database.transaction(() async {
        final changed = await _compareAndSetState(
          updated,
          expectedState: row!.operationState,
        );
        if (!changed) {
          return const FailureResult(
            ConflictFailure(
              message: 'Offline operation state changed concurrently.',
            ),
          );
        }
        if (_blocksDependencies(next)) {
          await _cancelDescendants(
            accountId,
            operationId,
            transitionedAt: updated.updatedAt,
          );
        }
        return Success(updated);
      });
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to transition offline operation.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to transition offline operation.',
          cause: error,
        ),
      );
    }
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
    final claimed = replacement.copyWith(replacementOf: conflictedOperationId);
    try {
      return await database.transaction(() async {
        final existing = await _findResolution(
          accountId,
          conflictedOperationId,
        );
        if (existing != null) {
          return _replayOrConflict(
            existing.replacement,
            claimed,
            existing.edgeDependencyFingerprint,
            dependencyFingerprint,
          );
        }
        final original = await _find(accountId, conflictedOperationId);
        if (original == null ||
            original.operationState != OutboxState.conflict.wireValue) {
          return const FailureResult(
            StateFailure(
              message: 'Only a conflicted operation can be resolved.',
            ),
          );
        }
        if (replacement.operationId == original.operationId ||
            replacement.idempotencyKey == original.idempotencyKey ||
            replacement.warehouseId != original.warehouseId ||
            replacement.kind.wireValue != original.operationKind) {
          return const FailureResult(
            ValidationFailure(
              message: 'Conflict replacement does not match original scope.',
            ),
          );
        }
        await _validateCapacity(accountId);
        await _validateIdentity(claimed);
        await _validateDependencies(claimed, dependencies);
        await _insertOperation(claimed, dependencies, payloadJson);
        await database
            .into(database.offlineOutboxResolutions)
            .insert(
              OfflineOutboxResolutionsCompanion.insert(
                originalOperationId: conflictedOperationId,
                replacementOperationId: claimed.operationId,
                accountId: accountId,
                dependencyFingerprint: dependencyFingerprint,
              ),
            );
        return Success(claimed);
      });
    } on _OutboxValidationException catch (error) {
      return FailureResult(ValidationFailure(message: error.message));
    } on _OutboxCapacityException catch (error) {
      return FailureResult(StateFailure(message: error.message));
    } on SqliteException catch (error) {
      final existing = await _findResolutionAfterClaimRace(
        accountId,
        conflictedOperationId,
      );
      if (existing != null) {
        return _replayOrConflict(
          existing.replacement,
          claimed,
          existing.edgeDependencyFingerprint,
          dependencyFingerprint,
        );
      }
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to resolve offline conflict.',
          cause: error,
        ),
      );
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to resolve offline conflict.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to resolve offline conflict.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<int>> prune({required String accountId}) async {
    final currentTime = now().toUtc();
    try {
      final deleted = await database.transaction(() async {
        final operations = await (database.select(
          database.offlineOutboxOperations,
        )..where((row) => row.accountId.equals(accountId))).get();
        if (operations.isEmpty) return 0;

        final operationIds = operations
            .map((operation) => operation.operationId)
            .toSet();
        final edges =
            await (database.select(database.offlineOutboxDependencies)..where(
                  (edge) =>
                      edge.operationId.isIn(operationIds) &
                      edge.dependencyId.isIn(operationIds),
                ))
                .get();
        final byId = {
          for (final operation in operations) operation.operationId: operation,
        };
        final children = {
          for (final operationId in operationIds) operationId: <String>{},
        };
        for (final edge in edges) {
          children[edge.dependencyId]!.add(edge.operationId);
        }
        final expiredIds = <String>{};
        for (final operation in operations) {
          if (!_isExpiredTerminal(operation, currentTime)) continue;
          final state = OutboxState.values.singleWhere(
            (candidate) => candidate.wireValue == operation.operationState,
          );
          if (state != OutboxState.succeeded &&
              _hasActiveDescendant(operation.operationId, children, byId)) {
            continue;
          }
          expiredIds.add(operation.operationId);
        }

        final resolutions = await (database.select(
          database.offlineOutboxResolutions,
        )..where((resolution) => resolution.accountId.equals(accountId))).get();
        final removableResolutionOriginalIds = <String>{};
        for (final resolution in resolutions) {
          final originalExpired = expiredIds.contains(
            resolution.originalOperationId,
          );
          final replacementExpired = expiredIds.contains(
            resolution.replacementOperationId,
          );
          if (originalExpired && replacementExpired) {
            removableResolutionOriginalIds.add(resolution.originalOperationId);
          } else if (originalExpired || replacementExpired) {
            expiredIds
              ..remove(resolution.originalOperationId)
              ..remove(resolution.replacementOperationId);
          }
        }

        if (expiredIds.isEmpty) return 0;
        if (removableResolutionOriginalIds.isNotEmpty) {
          await (database.delete(database.offlineOutboxResolutions)..where(
                (resolution) => resolution.originalOperationId.isIn(
                  removableResolutionOriginalIds,
                ),
              ))
              .go();
        }
        await (database.delete(database.offlineOutboxDependencies)..where(
              (edge) =>
                  edge.operationId.isIn(expiredIds) |
                  edge.dependencyId.isIn(expiredIds),
            ))
            .go();
        return (database.delete(database.offlineOutboxOperations)..where(
              (operation) =>
                  operation.accountId.equals(accountId) &
                  operation.operationId.isIn(expiredIds),
            ))
            .go();
      });
      return Success(deleted);
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to prune offline operations.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to prune offline operations.',
          cause: error,
        ),
      );
    }
  }

  Future<void> _validateCapacity(String accountId) async {
    final count = database.offlineOutboxOperations.operationId.count();
    final row =
        await (database.selectOnly(database.offlineOutboxOperations)
              ..addColumns([count])
              ..where(
                database.offlineOutboxOperations.accountId.equals(accountId) &
                    database.offlineOutboxOperations.operationState.isIn([
                      OutboxState.queued.wireValue,
                      OutboxState.syncing.wireValue,
                      OutboxState.retryableFailure.wireValue,
                    ]),
              ))
            .getSingle();
    if ((row.read(count) ?? 0) >= maxOperationsPerAccount) {
      throw const _OutboxCapacityException(
        'The offline outbox limit is 500 operations.',
      );
    }
  }

  Future<void> _validateIdentity(OutboxOperation operation) async {
    final existing =
        await (database.select(database.offlineOutboxOperations)
              ..where(
                (row) =>
                    row.operationId.equals(operation.operationId) |
                    (row.accountId.equals(operation.accountId) &
                        row.idempotencyKey.equals(operation.idempotencyKey)),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      throw const _OutboxValidationException(
        'The operation id or idempotency key already exists.',
      );
    }
  }

  Future<void> _validateDependencies(
    OutboxOperation operation,
    Set<String> dependencies,
  ) async {
    if (dependencies.isEmpty) return;
    final parents = await (database.select(
      database.offlineOutboxOperations,
    )..where((row) => row.operationId.isIn(dependencies))).get();
    if (parents.length != dependencies.length ||
        parents.any((parent) => parent.accountId != operation.accountId)) {
      throw const _OutboxValidationException(
        'Dependencies must exist in the same account.',
      );
    }

    for (final dependency in dependencies) {
      final cycle = await database
          .customSelect(
            '''
WITH RECURSIVE ancestors(operation_id) AS (
  SELECT dependency_id FROM outbox_dependencies WHERE operation_id = ?
  UNION
  SELECT edge.dependency_id
  FROM outbox_dependencies AS edge
  JOIN ancestors ON edge.operation_id = ancestors.operation_id
)
SELECT 1 AS found FROM ancestors WHERE operation_id = ? LIMIT 1
''',
            variables: [Variable(dependency), Variable(operation.operationId)],
            readsFrom: {database.offlineOutboxDependencies},
          )
          .getSingleOrNull();
      if (cycle != null) {
        throw const _OutboxValidationException(
          'The dependency graph cannot contain a cycle.',
        );
      }
    }
  }

  Future<OfflineOutboxOperation?> _find(String accountId, String operationId) {
    return (database.select(database.offlineOutboxOperations)..where(
          (row) =>
              row.accountId.equals(accountId) &
              row.operationId.equals(operationId),
        ))
        .getSingleOrNull();
  }

  Future<
    ({
      OfflineOutboxResolution resolution,
      OfflineOutboxOperation replacement,
      String edgeDependencyFingerprint,
    })?
  >
  _findResolution(String accountId, String conflictedOperationId) async {
    final resolution =
        await (database.select(database.offlineOutboxResolutions)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.originalOperationId.equals(conflictedOperationId),
            ))
            .getSingleOrNull();
    if (resolution == null) return null;
    final replacement = await _find(
      accountId,
      resolution.replacementOperationId,
    );
    if (replacement == null) {
      throw StateError('Outbox resolution replacement is missing.');
    }
    final edges =
        await (database.select(database.offlineOutboxDependencies)..where(
              (edge) =>
                  edge.operationId.equals(resolution.replacementOperationId),
            ))
            .get();
    return (
      resolution: resolution,
      replacement: replacement,
      edgeDependencyFingerprint: _dependencyFingerprint(
        edges.map((edge) => edge.dependencyId).toSet(),
      ),
    );
  }

  Future<
    ({
      OfflineOutboxResolution resolution,
      OfflineOutboxOperation replacement,
      String edgeDependencyFingerprint,
    })?
  >
  _findResolutionAfterClaimRace(
    String accountId,
    String conflictedOperationId,
  ) async {
    try {
      for (var attempt = 0; attempt < 3; attempt += 1) {
        final existing = await _findResolution(
          accountId,
          conflictedOperationId,
        );
        if (existing != null) return existing;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return null;
    } on StateError {
      return null;
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return null;
    }
  }

  Result<OutboxOperation> _replayOrConflict(
    OfflineOutboxOperation existing,
    OutboxOperation requested,
    String storedDependencyFingerprint,
    String requestedDependencyFingerprint,
  ) {
    final operation = _toDomainOperation(existing);
    final isSameRequest =
        operation.operationId == requested.operationId &&
        operation.idempotencyKey == requested.idempotencyKey &&
        operation.kind == requested.kind &&
        operation.warehouseId == requested.warehouseId &&
        _serializePayload(operation.payload) ==
            _serializePayload(requested.payload) &&
        storedDependencyFingerprint == requestedDependencyFingerprint;
    if (isSameRequest) return Success(operation);
    return const FailureResult(
      ConflictFailure(
        message: 'The conflicted operation already has a replacement.',
      ),
    );
  }

  Future<void> _insertOperation(
    OutboxOperation operation,
    Set<String> dependencies,
    String payloadJson,
  ) async {
    await database
        .into(database.offlineOutboxOperations)
        .insert(
          OfflineOutboxOperationsCompanion.insert(
            operationId: operation.operationId,
            idempotencyKey: operation.idempotencyKey,
            accountId: operation.accountId,
            warehouseId: operation.warehouseId,
            operationKind: operation.kind.wireValue,
            payload: payloadJson,
            operationState: operation.state.wireValue,
            createdAt: operation.createdAt.toUtc(),
            updatedAt: Value(operation.updatedAt.toUtc()),
            confirmedAt: Value(operation.confirmedAt?.toUtc()),
            nextAttemptAt: Value(operation.nextAttemptAt?.toUtc()),
            attemptCount: Value(operation.attemptCount),
            lastFailureCode: Value(operation.lastFailureCode),
            replacementOf: Value(operation.replacementOf),
          ),
        );
    for (final dependency in dependencies) {
      await database
          .into(database.offlineOutboxDependencies)
          .insert(
            OfflineOutboxDependenciesCompanion.insert(
              operationId: operation.operationId,
              dependencyId: dependency,
            ),
          );
    }
  }

  Future<bool> _compareAndSetState(
    OutboxOperation operation, {
    required String expectedState,
  }) async {
    final changed = await database.customUpdate(
      '''
UPDATE outbox_operations
SET operation_state = ?, updated_at = ?, next_attempt_at = ?,
    attempt_count = ?, last_failure_code = ?
WHERE account_id = ? AND operation_id = ? AND operation_state = ?
''',
      variables: [
        Variable(operation.state.wireValue),
        Variable(operation.updatedAt.toUtc()),
        Variable(operation.nextAttemptAt?.toUtc()),
        Variable(operation.attemptCount),
        Variable(operation.lastFailureCode),
        Variable(operation.accountId),
        Variable(operation.operationId),
        Variable(expectedState),
      ],
      updates: {database.offlineOutboxOperations},
    );
    return changed == 1;
  }

  Future<void> _cancelDescendants(
    String accountId,
    String operationId, {
    required DateTime transitionedAt,
  }) async {
    await database.customUpdate(
      '''
WITH RECURSIVE descendants(operation_id) AS (
  SELECT operation_id FROM outbox_dependencies WHERE dependency_id = ?
  UNION
  SELECT edge.operation_id
  FROM outbox_dependencies AS edge
  JOIN descendants ON edge.dependency_id = descendants.operation_id
)
UPDATE outbox_operations
SET operation_state = ?, updated_at = ?, next_attempt_at = NULL,
    last_failure_code = 'dependency_failed'
WHERE account_id = ?
  AND operation_id IN (SELECT operation_id FROM descendants)
  AND operation_state IN (?, ?)
''',
      variables: [
        Variable(operationId),
        Variable(OutboxState.cancelled.wireValue),
        Variable(transitionedAt.toUtc()),
        Variable(accountId),
        Variable(OutboxState.queued.wireValue),
        Variable(OutboxState.retryableFailure.wireValue),
      ],
      updates: {database.offlineOutboxOperations},
    );
  }

  bool _blocksDependencies(OutboxState state) =>
      state == OutboxState.conflict ||
      state == OutboxState.permanentFailure ||
      state == OutboxState.cancelled;

  bool _isExpiredTerminal(
    OfflineOutboxOperation operation,
    DateTime currentTime,
  ) {
    final state = OutboxState.values.singleWhere(
      (candidate) => candidate.wireValue == operation.operationState,
    );
    final transitionedAt = operation.updatedAt ?? operation.createdAt;
    return switch (state) {
      OutboxState.succeeded => transitionedAt.isBefore(
        currentTime.subtract(succeededRetention),
      ),
      OutboxState.conflict ||
      OutboxState.permanentFailure ||
      OutboxState.cancelled => transitionedAt.isBefore(
        currentTime.subtract(failedRetention),
      ),
      OutboxState.queued ||
      OutboxState.syncing ||
      OutboxState.retryableFailure => false,
    };
  }

  bool _hasActiveDescendant(
    String operationId,
    Map<String, Set<String>> children,
    Map<String, OfflineOutboxOperation> operations,
  ) {
    final pending = <String>[...children[operationId] ?? const <String>{}];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final childId = pending.removeLast();
      if (!visited.add(childId)) continue;
      final child = operations[childId];
      if (child != null &&
          (child.operationState == OutboxState.queued.wireValue ||
              child.operationState == OutboxState.syncing.wireValue ||
              child.operationState == OutboxState.retryableFailure.wireValue)) {
        return true;
      }
      pending.addAll(children[childId] ?? const <String>{});
    }
    return false;
  }

  OutboxOperation _toDomainOperation(OfflineOutboxOperation row) {
    return OutboxOperation(
      operationId: row.operationId,
      idempotencyKey: row.idempotencyKey,
      accountId: row.accountId,
      warehouseId: row.warehouseId,
      kind: OutboxOperationKind.values.singleWhere(
        (kind) => kind.wireValue == row.operationKind,
      ),
      payload: CacheRecordModel.decodePayload(row.payload),
      state: OutboxState.values.singleWhere(
        (state) => state.wireValue == row.operationState,
      ),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt ?? row.createdAt,
      confirmedAt: row.confirmedAt,
      nextAttemptAt: row.nextAttemptAt,
      attemptCount: row.attemptCount,
      lastFailureCode: row.lastFailureCode,
      replacementOf: row.replacementOf,
    );
  }
}

final class _OutboxValidationException implements Exception {
  const _OutboxValidationException(this.message);

  final String message;
}

final class _OutboxCapacityException implements Exception {
  const _OutboxCapacityException(this.message);

  final String message;
}

bool _isStorageException(Exception error) =>
    error is SqliteException ||
    error is DriftWrappedException ||
    error is InvalidDataException ||
    error is FormatException;

String _dependencyFingerprint(Set<String> dependencies) {
  final sorted = dependencies.toList()..sort();
  return jsonEncode(sorted);
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
