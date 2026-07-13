import 'package:drift/drift.dart';

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
    if (dependencies.contains(operation.operationId)) {
      return const FailureResult(
        ValidationFailure(message: 'An operation cannot depend on itself.'),
      );
    }

    try {
      await database.transaction(() async {
        await _validateCapacity(operation.accountId);
        await _validateIdentity(operation);
        await _validateDependencies(operation, dependencies);
        await database
            .into(database.offlineOutboxOperations)
            .insert(
              OfflineOutboxOperationsCompanion.insert(
                operationId: operation.operationId,
                idempotencyKey: operation.idempotencyKey,
                accountId: operation.accountId,
                warehouseId: operation.warehouseId,
                operationKind: operation.kind.wireValue,
                payload: CacheRecordModel.canonicalJson(operation.payload),
                operationState: operation.state.wireValue,
                createdAt: operation.createdAt.toUtc(),
                updatedAt: Value(operation.updatedAt.toUtc()),
                confirmedAt: Value(operation.confirmedAt?.toUtc()),
                nextAttemptAt: Value(operation.nextAttemptAt?.toUtc()),
                attemptCount: Value(operation.attemptCount),
                lastFailureCode: Value(operation.lastFailureCode),
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
      });
      return Success(operation);
    } on _OutboxValidationException catch (error) {
      return FailureResult(ValidationFailure(message: error.message));
    } on _OutboxCapacityException catch (error) {
      return FailureResult(StateFailure(message: error.message));
    } on Object catch (error) {
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
    } on Object catch (error) {
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
    try {
      final currentTime = now().toUtc();
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
    } on Object catch (error) {
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
    try {
      return await database.transaction(() async {
        final row = await _find(accountId, operationId);
        if (row == null) {
          return const FailureResult(
            NotFoundFailure(message: 'Offline operation not found.'),
          );
        }
        final result = stateMachine.transition(
          _toDomainOperation(row),
          next,
          failure: failure,
        );
        if (result case FailureResult<OutboxOperation>()) return result;

        final updated = (result as Success<OutboxOperation>).data;
        await _writeState(updated);
        if (_blocksDependencies(next)) {
          await _cancelDescendants(accountId, operationId);
        }
        return Success(updated);
      });
    } on Object catch (error) {
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
    try {
      final original = await _find(accountId, conflictedOperationId);
      if (original == null ||
          original.operationState != OutboxState.conflict.wireValue) {
        return const FailureResult(
          StateFailure(message: 'Only a conflicted operation can be resolved.'),
        );
      }
      if (replacement.accountId != accountId ||
          replacement.operationId == original.operationId ||
          replacement.idempotencyKey == original.idempotencyKey) {
        return const FailureResult(
          ValidationFailure(
            message: 'Conflict resolution requires a new operation and key.',
          ),
        );
      }
      return enqueue(replacement, dependencies: dependencies);
    } on Object catch (error) {
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
    try {
      final currentTime = now().toUtc();
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
        final adjacency = {
          for (final operationId in operationIds) operationId: <String>{},
        };
        for (final edge in edges) {
          adjacency[edge.operationId]!.add(edge.dependencyId);
          adjacency[edge.dependencyId]!.add(edge.operationId);
        }

        final byId = {
          for (final operation in operations) operation.operationId: operation,
        };
        final expiredIds = <String>{};
        final visited = <String>{};
        for (final operationId in operationIds) {
          if (!visited.add(operationId)) continue;
          final component = <String>{operationId};
          final pending = <String>[operationId];
          while (pending.isNotEmpty) {
            final current = pending.removeLast();
            for (final neighbor in adjacency[current]!) {
              if (visited.add(neighbor)) {
                component.add(neighbor);
                pending.add(neighbor);
              }
            }
          }
          if (component.every(
            (id) => _isExpiredTerminal(byId[id]!, currentTime),
          )) {
            expiredIds.addAll(component);
          }
        }

        if (expiredIds.isEmpty) return 0;
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
    } on Object catch (error) {
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

  Future<void> _writeState(OutboxOperation operation) async {
    await (database.update(
      database.offlineOutboxOperations,
    )..where((row) => row.operationId.equals(operation.operationId))).write(
      OfflineOutboxOperationsCompanion(
        operationState: Value(operation.state.wireValue),
        updatedAt: Value(operation.updatedAt.toUtc()),
        nextAttemptAt: Value(operation.nextAttemptAt?.toUtc()),
        attemptCount: Value(operation.attemptCount),
        lastFailureCode: Value(operation.lastFailureCode),
      ),
    );
  }

  Future<void> _cancelDescendants(String accountId, String operationId) async {
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
        Variable(now().toUtc()),
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
