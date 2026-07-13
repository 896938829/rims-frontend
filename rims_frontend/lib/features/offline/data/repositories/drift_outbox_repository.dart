import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/entities/outbox_graph.dart';
import '../../domain/entities/outbox_cleanup_intent.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/idempotency_key_validator.dart';
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
  Future<Result<List<OutboxOperation>>> enqueueGraph(OutboxGraph graph) async {
    if (graph.operations.isEmpty) {
      return const FailureResult(
        ValidationFailure(message: 'An outbox graph cannot be empty.'),
      );
    }
    final byId = <String, OutboxOperation>{};
    final keys = <String>{};
    final payloads = <String, String>{};
    final accountId = graph.operations.first.accountId;
    final warehouseId = graph.operations.first.warehouseId;
    for (final operation in graph.operations) {
      if (operation.accountId != accountId ||
          operation.warehouseId != warehouseId ||
          operation.state != OutboxState.queued ||
          operation.replacementOf != null ||
          operation.operationId.isEmpty ||
          !IdempotencyKeyValidator.isValid(operation.idempotencyKey) ||
          byId.containsKey(operation.operationId) ||
          !keys.add(operation.idempotencyKey)) {
        return const FailureResult(
          ValidationFailure(message: 'The outbox graph is invalid.'),
        );
      }
      byId[operation.operationId] = operation;
      payloads[operation.operationId] = _serializePayload(operation.payload);
    }
    if (graph.dependencies.keys.any((id) => !byId.containsKey(id)) ||
        graph.dependencies.entries.any(
          (entry) => entry.value.contains(entry.key),
        ) ||
        _graphHasCycle(graph, byId.keys.toSet())) {
      return const FailureResult(
        ValidationFailure(message: 'The outbox dependency graph is invalid.'),
      );
    }

    try {
      final stored = await database.transaction(() async {
        final existing = await (database.select(
          database.offlineOutboxOperations,
        )..where((row) => row.operationId.isIn(byId.keys))).get();
        if (existing.isNotEmpty) {
          if (existing.length != graph.operations.length ||
              !await _isExactGraphReplay(graph, payloads, existing)) {
            throw const _OutboxConflictException(
              'The outbox graph already exists.',
            );
          }
          return existing.map(_toDomainOperation).toList(growable: false);
        }

        final activeCount = database.offlineOutboxOperations.operationId
            .count();
        final activeRow =
            await (database.selectOnly(database.offlineOutboxOperations)
                  ..addColumns([activeCount])
                  ..where(
                    database.offlineOutboxOperations.accountId.equals(
                          accountId,
                        ) &
                        database.offlineOutboxOperations.operationState.isIn([
                          OutboxState.queued.wireValue,
                          OutboxState.syncing.wireValue,
                          OutboxState.retryableFailure.wireValue,
                        ]),
                  ))
                .getSingle();
        if ((activeRow.read(activeCount) ?? 0) + graph.operations.length >
            maxOperationsPerAccount) {
          throw const _OutboxCapacityException(
            'The offline outbox limit is 500 operations.',
          );
        }
        final keyCollision =
            await (database.select(database.offlineOutboxOperations)
                  ..where(
                    (row) =>
                        row.accountId.equals(accountId) &
                        row.idempotencyKey.isIn(keys),
                  )
                  ..limit(1))
                .getSingleOrNull();
        if (keyCollision != null) {
          throw const _OutboxConflictException(
            'An idempotency key already exists.',
          );
        }

        final dependencyIds = graph.dependencies.values
            .expand((ids) => ids)
            .where((id) => !byId.containsKey(id))
            .toSet();
        if (dependencyIds.isNotEmpty) {
          final dependencies = await (database.select(
            database.offlineOutboxOperations,
          )..where((row) => row.operationId.isIn(dependencyIds))).get();
          if (dependencies.length != dependencyIds.length ||
              dependencies.any(
                (operation) =>
                    operation.accountId != accountId ||
                    operation.warehouseId != warehouseId,
              )) {
            throw const _OutboxValidationException(
              'Dependencies must exist in the same account and warehouse.',
            );
          }
        }

        for (final operation in graph.operations) {
          await _insertOperation(
            operation,
            const {},
            payloads[operation.operationId]!,
          );
        }
        for (final entry in graph.dependencies.entries) {
          for (final dependency in entry.value) {
            await database
                .into(database.offlineOutboxDependencies)
                .insert(
                  OfflineOutboxDependenciesCompanion.insert(
                    operationId: entry.key,
                    dependencyId: dependency,
                  ),
                );
          }
        }
        return graph.operations;
      });
      return Success(List.unmodifiable(stored));
    } on _OutboxValidationException catch (error) {
      return FailureResult(ValidationFailure(message: error.message));
    } on _OutboxConflictException catch (error) {
      return FailureResult(ConflictFailure(message: error.message));
    } on _OutboxCapacityException catch (error) {
      return FailureResult(StateFailure(message: error.message));
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to enqueue outbox graph.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to enqueue outbox graph.',
          cause: error,
        ),
      );
    }
  }

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
    if (!IdempotencyKeyValidator.isValid(operation.idempotencyKey)) {
      return const FailureResult(
        ValidationFailure(message: 'Invalid idempotency key.'),
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
  Future<Result<List<OutboxOperation>>> loadConnectedComponent({
    required String accountId,
    required Set<String> operationIds,
  }) async {
    try {
      return await database.transaction(() async {
        final operationQuery = database.select(database.offlineOutboxOperations)
          ..where((row) => row.accountId.equals(accountId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
            (row) => OrderingTerm.asc(row.operationId),
          ]);
        final operationRows = await operationQuery.get();
        final accountOperationIds = operationRows
            .map((row) => row.operationId)
            .toSet();
        final edgeRows = accountOperationIds.isEmpty
            ? const <OfflineOutboxDependency>[]
            : await (database.select(database.offlineOutboxDependencies)
                    ..where((row) => row.operationId.isIn(accountOperationIds)))
                  .get();
        final dependencies = <String, Set<String>>{};
        for (final edge in edgeRows) {
          if (!accountOperationIds.contains(edge.dependencyId)) continue;
          dependencies
              .putIfAbsent(edge.operationId, () => <String>{})
              .add(edge.dependencyId);
        }
        final connectedIds = _connectedOperationIds(
          accountOperationIds,
          dependencies,
          operationIds,
        );
        return Success(
          List.unmodifiable(
            operationRows
                .where((row) => connectedIds.contains(row.operationId))
                .map(_toDomainOperation),
          ),
        );
      });
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline dependency graph.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline dependency graph.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<OutboxOperation>>> ready(
    String accountId, {
    String? reviewStamp,
  }) async {
    final currentTime = now().toUtc();
    try {
      final rows = await database
          .customSelect(
            '''
SELECT operation.*
FROM outbox_operations AS operation
WHERE operation.account_id = ?
  AND operation.confirmed_at IS NOT NULL
  AND (? IS NULL OR operation.review_stamp = ?)
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
              Variable<String>(reviewStamp),
              Variable<String>(reviewStamp),
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
  Future<Result<OutboxOperation>> confirm({
    required String accountId,
    required String operationId,
    String? reviewStamp,
    DateTime? expectedUpdatedAt,
  }) async {
    final existing = await _findResult(accountId, operationId);
    if (existing case FailureResult<OutboxOperation>()) return existing;
    final operation = (existing as Success<OutboxOperation>).data;
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
    final timestamp = _nextReviewTimestamp(now(), operation.updatedAt);
    try {
      final changed = await database.customUpdate(
        '''
UPDATE outbox_operations
SET confirmed_at = ?, review_stamp = ?, updated_at = ?
WHERE account_id = ? AND operation_id = ? AND operation_state = ?
  AND (? IS NULL OR updated_at = ?)
''',
        variables: [
          Variable(timestamp),
          Variable<String>(reviewStamp),
          Variable(timestamp),
          Variable(accountId),
          Variable(operationId),
          Variable(operation.state.wireValue),
          Variable<DateTime>(expectedUpdatedAt?.toUtc()),
          Variable<DateTime>(expectedUpdatedAt?.toUtc()),
        ],
        updates: {database.offlineOutboxOperations},
      );
      if (changed != 1) {
        return const FailureResult(
          ConflictFailure(message: 'Offline review context changed.'),
        );
      }
      return Success(
        operation.copyWith(
          confirmedAt: timestamp,
          reviewStamp: reviewStamp,
          updatedAt: timestamp,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to confirm offline operation.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<OutboxOperation>>> invalidateReviewGraph({
    required String accountId,
    required Map<String, DateTime> expectedUpdatedAtByOperation,
  }) async {
    if (expectedUpdatedAtByOperation.isEmpty) return const Success([]);
    try {
      return await database.transaction(() async {
        final accountRows = await (database.select(
          database.offlineOutboxOperations,
        )..where((row) => row.accountId.equals(accountId))).get();
        final accountIds = accountRows.map((row) => row.operationId).toSet();
        final edges = await (database.select(
          database.offlineOutboxDependencies,
        )..where((row) => row.operationId.isIn(accountIds))).get();
        final dependencies = <String, Set<String>>{};
        for (final edge in edges) {
          if (!accountIds.contains(edge.dependencyId)) continue;
          dependencies
              .putIfAbsent(edge.operationId, () => <String>{})
              .add(edge.dependencyId);
        }
        final requestedIds = expectedUpdatedAtByOperation.keys.toSet();
        final connectedIds = _connectedOperationIds(
          accountIds,
          dependencies,
          requestedIds,
        );
        if (connectedIds.length != requestedIds.length ||
            !connectedIds.containsAll(requestedIds)) {
          throw const _OutboxValidationException(
            'Review invalidation requires a full graph.',
          );
        }
        final rowsById = {for (final row in accountRows) row.operationId: row};
        for (final entry in expectedUpdatedAtByOperation.entries) {
          final row = rowsById[entry.key];
          if (row == null || row.updatedAt?.toUtc() != entry.value.toUtc()) {
            throw const _OutboxConflictException(
              'Offline review context changed.',
            );
          }
        }
        final result = <OutboxOperation>[];
        for (final operationId in requestedIds) {
          final operation = _toDomainOperation(rowsById[operationId]!);
          if (!_isActiveState(operation.state) ||
              (operation.confirmedAt == null &&
                  operation.reviewStamp == null)) {
            result.add(operation);
            continue;
          }
          final timestamp = _nextReviewTimestamp(now(), operation.updatedAt);
          final changed = await database.customUpdate(
            '''
UPDATE outbox_operations
SET confirmed_at = NULL, review_stamp = NULL, updated_at = ?
WHERE account_id = ? AND operation_id = ? AND updated_at = ?
  AND operation_state IN (?, ?, ?)
''',
            variables: [
              Variable(timestamp),
              Variable(accountId),
              Variable(operationId),
              Variable(operation.updatedAt.toUtc()),
              Variable(OutboxState.queued.wireValue),
              Variable(OutboxState.syncing.wireValue),
              Variable(OutboxState.retryableFailure.wireValue),
            ],
            updates: {database.offlineOutboxOperations},
          );
          if (changed != 1) {
            throw const _OutboxConflictException(
              'Offline review context changed.',
            );
          }
          result.add(
            operation.copyWith(updatedAt: timestamp, clearReview: true),
          );
        }
        result.sort(_compareOperations);
        return Success(List.unmodifiable(result));
      });
    } on _OutboxValidationException catch (error) {
      return FailureResult(ValidationFailure(message: error.message));
    } on _OutboxConflictException catch (error) {
      return FailureResult(ConflictFailure(message: error.message));
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to invalidate offline review graph.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<int>> recoverStaleSyncing({
    required String accountId,
    required DateTime staleBefore,
    required Set<String> operationIds,
  }) async {
    if (operationIds.isEmpty) return const Success(0);
    final timestamp = now().toUtc();
    final sortedIds = operationIds.toList()..sort();
    final placeholders = List.filled(sortedIds.length, '?').join(', ');
    try {
      final changed = await database.customUpdate(
        '''
UPDATE outbox_operations
SET operation_state = ?, updated_at = ?, next_attempt_at = ?,
    attempt_count = attempt_count + 1, last_failure_code = 'unknown_result',
    requires_status_probe = 1, syncing_started_at = NULL
WHERE account_id = ? AND operation_state = ?
  AND syncing_started_at IS NOT NULL AND syncing_started_at <= ?
  AND operation_id IN ($placeholders)
''',
        variables: [
          Variable(OutboxState.retryableFailure.wireValue),
          Variable(timestamp),
          Variable(timestamp),
          Variable(accountId),
          Variable(OutboxState.syncing.wireValue),
          Variable(staleBefore.toUtc()),
          for (final operationId in sortedIds) Variable(operationId),
        ],
        updates: {database.offlineOutboxOperations},
      );
      return Success(changed);
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to recover interrupted synchronization.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<OutboxOperation>> retryNow({
    required String accountId,
    required String operationId,
  }) async {
    final existing = await _findResult(accountId, operationId);
    if (existing case FailureResult<OutboxOperation>()) return existing;
    final operation = (existing as Success<OutboxOperation>).data;
    if (operation.state == OutboxState.queued) return Success(operation);
    if (operation.state != OutboxState.retryableFailure) {
      return const FailureResult(
        StateFailure(message: 'Only retryable offline work can retry now.'),
      );
    }
    return _updateWaitingOperation(
      accountId: accountId,
      operationId: operationId,
      allowQueued: false,
      message: 'Unable to schedule offline retry.',
      update: (operation, timestamp) =>
          operation.copyWith(updatedAt: timestamp, clearNextAttemptAt: true),
      companion: (timestamp) => OfflineOutboxOperationsCompanion(
        nextAttemptAt: const Value(null),
        updatedAt: Value(timestamp),
      ),
    );
  }

  Future<Result<OutboxOperation>> _findResult(
    String accountId,
    String operationId,
  ) async {
    try {
      final row = await _find(accountId, operationId);
      if (row == null) {
        return const FailureResult(
          NotFoundFailure(message: 'Offline operation not found.'),
        );
      }
      return Success(_toDomainOperation(row));
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operation.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read offline operation.',
          cause: error,
        ),
      );
    }
  }

  Future<Result<OutboxOperation>> _updateWaitingOperation({
    required String accountId,
    required String operationId,
    required bool allowQueued,
    required String message,
    required OutboxOperation Function(
      OutboxOperation operation,
      DateTime timestamp,
    )
    update,
    required OfflineOutboxOperationsCompanion Function(DateTime timestamp)
    companion,
  }) async {
    final existing = await _findResult(accountId, operationId);
    if (existing case FailureResult<OutboxOperation>()) return existing;
    final operation = (existing as Success<OutboxOperation>).data;
    final allowed =
        operation.state == OutboxState.retryableFailure ||
        (allowQueued && operation.state == OutboxState.queued);
    if (!allowed) {
      return const FailureResult(
        StateFailure(message: 'Only waiting offline work can be updated.'),
      );
    }
    final timestamp = now().toUtc();
    try {
      final changed =
          await (database.update(database.offlineOutboxOperations)..where(
                (entry) =>
                    entry.operationId.equals(operationId) &
                    entry.accountId.equals(accountId) &
                    entry.operationState.equals(operation.state.wireValue),
              ))
              .write(companion(timestamp));
      if (changed != 1) {
        return const FailureResult(
          ConflictFailure(
            message: 'Offline operation state changed concurrently.',
          ),
        );
      }
      return Success(update(operation, timestamp));
    } on StateError catch (error) {
      return FailureResult(LocalStorageFailure(message: message, cause: error));
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(LocalStorageFailure(message: message, cause: error));
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
  Future<Result<OutboxOperation>> completeSuccess({
    required String accountId,
    required String operationId,
    required OutboxOperationOutput output,
    OutboxCleanupRequest? cleanup,
  }) async {
    final existing = await _findResult(accountId, operationId);
    if (existing case FailureResult<OutboxOperation>()) return existing;
    final current = (existing as Success<OutboxOperation>).data;
    if (current.state != OutboxState.syncing || output.version <= 0) {
      return const FailureResult(
        StateFailure(message: 'Only syncing work can complete successfully.'),
      );
    }
    final outputJson = _serializePayload({
      'version': output.version,
      'data': output.data,
    });
    final transitioned = stateMachine.transition(
      current,
      OutboxState.succeeded,
    );
    if (transitioned case FailureResult<OutboxOperation>()) return transitioned;
    final completed = (transitioned as Success<OutboxOperation>).data.copyWith(
      output: output,
    );
    try {
      await database.transaction(() async {
        final changed = await database.customUpdate(
          '''
UPDATE outbox_operations
SET operation_state = ?, updated_at = ?, next_attempt_at = NULL,
    last_failure_code = NULL, requires_status_probe = 0,
    syncing_started_at = NULL, output = ?
WHERE account_id = ? AND operation_id = ? AND operation_state = ?
''',
          variables: [
            Variable(completed.state.wireValue),
            Variable(completed.updatedAt.toUtc()),
            Variable(outputJson),
            Variable(accountId),
            Variable(operationId),
            Variable(OutboxState.syncing.wireValue),
          ],
          updates: {database.offlineOutboxOperations},
        );
        if (changed != 1) {
          throw const _OutboxConflictException(
            'Offline operation state changed concurrently.',
          );
        }
        if (cleanup != null) {
          await database
              .into(database.offlineOutboxCleanupIntents)
              .insert(
                OfflineOutboxCleanupIntentsCompanion.insert(
                  operationId: operationId,
                  accountId: accountId,
                  warehouseId: current.warehouseId,
                  draftId: Value(cleanup.draftId),
                  attachmentRequestIds: jsonEncode(
                    cleanup.attachmentRequestIds,
                  ),
                  createdAt: completed.updatedAt.toUtc(),
                  updatedAt: completed.updatedAt.toUtc(),
                ),
              );
        }
      });
      return Success(completed);
    } on _OutboxConflictException catch (error) {
      return FailureResult(ConflictFailure(message: error.message));
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to complete offline operation.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<Map<String, OutboxOperationOutput>>> loadDependencyOutputs({
    required String accountId,
    required String operationId,
  }) async {
    final owned = await _find(accountId, operationId);
    if (owned == null) {
      return const FailureResult(
        NotFoundFailure(message: 'Offline operation not found.'),
      );
    }
    try {
      final rows = await database
          .customSelect(
            '''
SELECT parent.operation_id, parent.output
FROM outbox_dependencies AS edge
JOIN outbox_operations AS parent
  ON parent.operation_id = edge.dependency_id
WHERE edge.operation_id = ? AND parent.account_id = ?
''',
            variables: [Variable(operationId), Variable(accountId)],
            readsFrom: {
              database.offlineOutboxDependencies,
              database.offlineOutboxOperations,
            },
          )
          .get();
      final outputs = <String, OutboxOperationOutput>{};
      for (final row in rows) {
        final encoded = row.read<String?>('output');
        if (encoded != null) {
          outputs[row.read<String>('operation_id')] = _decodeOutput(encoded);
        }
      }
      return Success(Map.unmodifiable(outputs));
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read dependency outputs.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<OutboxCleanupIntent>>> listCleanupIntents(
    String accountId,
  ) async {
    try {
      final query = database.select(database.offlineOutboxCleanupIntents)
        ..where((row) => row.accountId.equals(accountId))
        ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]);
      final rows = await query.get();
      return Success(List.unmodifiable(rows.map(_toCleanupIntent)));
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to read cleanup intents.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> recordCleanupFailure({
    required String accountId,
    required String operationId,
    required String failure,
  }) async {
    try {
      final changed = await database.customUpdate(
        '''
UPDATE outbox_cleanup_intents
SET attempt_count = attempt_count + 1, last_failure = ?, updated_at = ?
WHERE account_id = ? AND operation_id = ?
''',
        variables: [
          Variable(failure),
          Variable(now().toUtc()),
          Variable(accountId),
          Variable(operationId),
        ],
        updates: {database.offlineOutboxCleanupIntents},
      );
      if (changed != 1) {
        return const FailureResult(
          NotFoundFailure(message: 'Cleanup intent not found.'),
        );
      }
      return const Success(null);
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to retain cleanup failure.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> completeCleanupIntent({
    required String accountId,
    required String operationId,
  }) async {
    try {
      await (database.delete(database.offlineOutboxCleanupIntents)..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.operationId.equals(operationId),
          ))
          .go();
      return const Success(null);
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to complete cleanup intent.',
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
  Future<Result<OutboxOperation>> discard({
    required String accountId,
    required String operationId,
  }) async {
    try {
      return await database.transaction(() async {
        final row = await _find(accountId, operationId);
        if (row == null) {
          return const FailureResult(
            NotFoundFailure(message: 'Offline operation not found.'),
          );
        }
        final operation = _toDomainOperation(row);
        if (!_isTerminal(operation.state)) {
          return const FailureResult(
            StateFailure(
              message: 'Only completed offline work can be discarded.',
            ),
          );
        }
        final dependent = await database
            .customSelect(
              '''
SELECT 1
FROM outbox_dependencies AS edge
JOIN outbox_operations AS operation
  ON operation.operation_id = edge.operation_id
WHERE edge.dependency_id = ? AND operation.account_id = ?
LIMIT 1
''',
              variables: [Variable(operationId), Variable(accountId)],
              readsFrom: {
                database.offlineOutboxDependencies,
                database.offlineOutboxOperations,
              },
            )
            .getSingleOrNull();
        if (dependent != null) {
          return const FailureResult(
            StateFailure(
              message: 'Offline work with dependents cannot be discarded.',
            ),
          );
        }
        await (database.delete(database.offlineOutboxOperations)..where(
              (entry) =>
                  entry.operationId.equals(operationId) &
                  entry.accountId.equals(accountId),
            ))
            .go();
        return Success(operation);
      });
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to discard offline operation.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to discard offline operation.',
          cause: error,
        ),
      );
    }
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
            payloadJson,
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
          payloadJson,
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
  Future<Result<void>> clearAccount(String accountId) async {
    try {
      await database.clearAccount(accountId);
      return const Success<void>(null);
    } on StateError catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to clear offline account data.',
          cause: error,
        ),
      );
    } on Exception catch (error) {
      if (!_isStorageException(error)) rethrow;
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to clear offline account data.',
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
        final cleanupOperationIds =
            await (database.selectOnly(database.offlineOutboxCleanupIntents)
                  ..addColumns([
                    database.offlineOutboxCleanupIntents.operationId,
                  ])
                  ..where(
                    database.offlineOutboxCleanupIntents.accountId.equals(
                      accountId,
                    ),
                  ))
                .map(
                  (row) => row.read(
                    database.offlineOutboxCleanupIntents.operationId,
                  )!,
                )
                .get();
        final expiredCandidates = <String>{};
        for (final operation in operations) {
          if (cleanupOperationIds.contains(operation.operationId)) continue;
          if (!_isExpiredTerminal(operation, currentTime)) continue;
          expiredCandidates.add(operation.operationId);
        }
        final expiredIds = expiredCandidates.where((operationId) {
          return !_hasRecoverableDescendantOutside(
            operationId,
            children,
            byId,
            expiredCandidates,
          );
        }).toSet();

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
        parents.any(
          (parent) =>
              parent.accountId != operation.accountId ||
              parent.warehouseId != operation.warehouseId,
        )) {
      throw const _OutboxValidationException(
        'Dependencies must exist in the same account and warehouse.',
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
    String requestedPayloadJson,
    String storedDependencyFingerprint,
    String requestedDependencyFingerprint,
  ) {
    final operation = _toDomainOperation(existing);
    final isSameRequest =
        operation.operationId == requested.operationId &&
        operation.idempotencyKey == requested.idempotencyKey &&
        operation.kind == requested.kind &&
        operation.warehouseId == requested.warehouseId &&
        _serializePayload(operation.payload) == requestedPayloadJson &&
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
            reviewStamp: Value(operation.reviewStamp),
            requiresStatusProbe: Value(operation.requiresStatusProbe),
            syncingStartedAt: Value(operation.syncingStartedAt?.toUtc()),
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
    attempt_count = ?, last_failure_code = ?, requires_status_probe = ?,
    syncing_started_at = ?
WHERE account_id = ? AND operation_id = ? AND operation_state = ?
''',
      variables: [
        Variable(operation.state.wireValue),
        Variable(operation.updatedAt.toUtc()),
        Variable(operation.nextAttemptAt?.toUtc()),
        Variable(operation.attemptCount),
        Variable(operation.lastFailureCode),
        Variable(operation.requiresStatusProbe),
        Variable(operation.syncingStartedAt?.toUtc()),
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

  bool _hasRecoverableDescendantOutside(
    String operationId,
    Map<String, Set<String>> children,
    Map<String, OfflineOutboxOperation> operations,
    Set<String> expiredCandidates,
  ) {
    final pending = <String>[...children[operationId] ?? const <String>{}];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final childId = pending.removeLast();
      if (!visited.add(childId)) continue;
      final child = operations[childId];
      if (child != null &&
          !expiredCandidates.contains(childId) &&
          (child.operationState == OutboxState.queued.wireValue ||
              child.operationState == OutboxState.syncing.wireValue ||
              child.operationState == OutboxState.retryableFailure.wireValue ||
              child.operationState == OutboxState.conflict.wireValue)) {
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
      reviewStamp: row.reviewStamp,
      requiresStatusProbe: row.requiresStatusProbe,
      syncingStartedAt: row.syncingStartedAt,
      output: row.output == null ? null : _decodeOutput(row.output!),
    );
  }

  OutboxCleanupIntent _toCleanupIntent(OfflineOutboxCleanupIntent row) {
    return OutboxCleanupIntent(
      operationId: row.operationId,
      accountId: row.accountId,
      warehouseId: row.warehouseId,
      draftId: row.draftId,
      attachmentRequestIds: (jsonDecode(row.attachmentRequestIds) as List)
          .cast<String>(),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      attemptCount: row.attemptCount,
      lastFailure: row.lastFailure,
    );
  }

  Future<bool> _isExactGraphReplay(
    OutboxGraph graph,
    Map<String, String> payloads,
    List<OfflineOutboxOperation> existing,
  ) async {
    final storedById = {for (final row in existing) row.operationId: row};
    final edges = await (database.select(
      database.offlineOutboxDependencies,
    )..where((edge) => edge.operationId.isIn(storedById.keys))).get();
    final dependencies = <String, Set<String>>{};
    for (final edge in edges) {
      dependencies
          .putIfAbsent(edge.operationId, () => <String>{})
          .add(edge.dependencyId);
    }
    for (final requested in graph.operations) {
      final stored = storedById[requested.operationId];
      if (stored == null ||
          stored.accountId != requested.accountId ||
          stored.warehouseId != requested.warehouseId ||
          stored.operationKind != requested.kind.wireValue ||
          stored.idempotencyKey != requested.idempotencyKey ||
          stored.payload != payloads[requested.operationId] ||
          _dependencyFingerprint(
                dependencies[requested.operationId] ?? const {},
              ) !=
              _dependencyFingerprint(
                graph.dependencies[requested.operationId] ?? const {},
              )) {
        return false;
      }
    }
    return true;
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

final class _OutboxConflictException implements Exception {
  const _OutboxConflictException(this.message);

  final String message;
}

OutboxOperationOutput _decodeOutput(String encoded) {
  final envelope = jsonDecode(encoded);
  if (envelope is! Map ||
      envelope['version'] is! int ||
      envelope['data'] is! Map) {
    throw const FormatException('Invalid outbox operation output.');
  }
  return OutboxOperationOutput(
    version: envelope['version'] as int,
    data: Map<String, Object?>.from(envelope['data'] as Map),
  );
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

bool _isStorageException(Exception error) =>
    error is SqliteException ||
    error is DriftWrappedException ||
    error is InvalidDataException ||
    error is FormatException;

String _dependencyFingerprint(Set<String> dependencies) {
  final sorted = dependencies.toList()..sort();
  return jsonEncode(sorted);
}

DateTime _nextReviewTimestamp(DateTime now, DateTime current) {
  final candidate = now.toUtc();
  final minimum = current.toUtc().add(const Duration(seconds: 1));
  return candidate.isAfter(minimum) ? candidate : minimum;
}

int _compareOperations(OutboxOperation left, OutboxOperation right) {
  final byTime = left.createdAt.compareTo(right.createdAt);
  return byTime != 0 ? byTime : left.operationId.compareTo(right.operationId);
}

bool _isActiveState(OutboxState state) =>
    state == OutboxState.queued ||
    state == OutboxState.syncing ||
    state == OutboxState.retryableFailure;

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
