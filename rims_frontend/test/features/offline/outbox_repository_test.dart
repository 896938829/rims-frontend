import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);
  late OfflineDatabase database;
  late OutboxRepository repository;
  late DateTime clock;

  setUp(() {
    clock = now;
    database = OfflineDatabase.forTesting(NativeDatabase.memory());
    repository = DriftOutboxRepository(
      database: database,
      stateMachine: OutboxStateMachine(
        now: () => clock,
        retryBackoff: (attempt) => Duration(minutes: attempt),
      ),
      now: () => clock,
    );
  });

  tearDown(() => database.close());

  test(
    'enqueue rejects self, missing, and cross-account dependencies atomically',
    () async {
      await repository.enqueue(_operation('parent'));
      await repository.enqueue(_operation('other', accountId: '8'));

      for (final (operation, dependencies) in [
        (_operation('self'), const {'self'}),
        (_operation('missing'), const {'not-there'}),
        (_operation('cross'), const {'other'}),
      ]) {
        final result = await repository.enqueue(
          operation,
          dependencies: dependencies,
        );
        expect(result, isA<FailureResult<OutboxOperation>>());
        expect(
          (result as FailureResult<OutboxOperation>).failure,
          isA<ValidationFailure>(),
        );
      }

      expect((await repository.list('7')).getOrThrow(), hasLength(1));
    },
  );

  test('enqueue detects dependency cycles atomically', () async {
    await repository.enqueue(_operation('parent'));
    await database.customStatement('PRAGMA foreign_keys = OFF');
    await database.customStatement(
      "INSERT INTO outbox_dependencies (operation_id, dependency_id) "
      "VALUES ('parent', 'child')",
    );
    await database.customStatement('PRAGMA foreign_keys = ON');

    final result = await repository.enqueue(
      _operation('child'),
      dependencies: const {'parent'},
    );

    expect(result, isA<FailureResult<OutboxOperation>>());
    expect(
      (result as FailureResult<OutboxOperation>).failure,
      isA<ValidationFailure>(),
    );
    expect((await repository.list('7')).getOrThrow(), hasLength(1));
  });

  test('ready operations are stable FIFO and honor retry schedule', () async {
    await repository.enqueue(_operation('b', createdAt: now));
    await repository.enqueue(_operation('a', createdAt: now));
    await repository.enqueue(
      _operation(
        'retry-later',
        state: OutboxState.retryableFailure,
        createdAt: now.subtract(const Duration(minutes: 1)),
        nextAttemptAt: now.add(const Duration(seconds: 1)),
      ),
    );
    await repository.enqueue(
      _operation(
        'retry-now',
        state: OutboxState.retryableFailure,
        createdAt: now.subtract(const Duration(minutes: 2)),
        nextAttemptAt: now,
      ),
    );

    final ready = (await repository.ready('7')).getOrThrow();
    expect(ready.map((operation) => operation.operationId), [
      'retry-now',
      'a',
      'b',
    ]);
  });

  test(
    'terminal dependency failure propagates visibly to descendants',
    () async {
      await repository.enqueue(_operation('parent'));
      await repository.enqueue(
        _operation('child'),
        dependencies: const {'parent'},
      );
      await repository.enqueue(
        _operation('grandchild'),
        dependencies: const {'child'},
      );
      await repository.transition(
        accountId: '7',
        operationId: 'parent',
        next: OutboxState.syncing,
      );

      final result = await repository.transition(
        accountId: '7',
        operationId: 'parent',
        next: OutboxState.permanentFailure,
        failure: const ValidationFailure(message: 'rejected'),
      );

      expect(result, isA<Success<OutboxOperation>>());
      final operations = (await repository.list('7')).getOrThrow();
      expect(
        operations
            .where((item) => item.operationId != 'parent')
            .map((item) => item.state),
        everyElement(OutboxState.cancelled),
      );
      expect(
        operations
            .where((item) => item.operationId != 'parent')
            .map((item) => item.lastFailureCode),
        everyElement('dependency_failed'),
      );
    },
  );

  test(
    'conflict resolution creates a new operation and never mutates original payload',
    () async {
      await repository.enqueue(
        _operation('original', payload: const {'quantity': 1}),
      );
      await repository.transition(
        accountId: '7',
        operationId: 'original',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'original',
        next: OutboxState.conflict,
        failure: const ConflictFailure(),
      );

      final result = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'original',
        replacement: _operation(
          'replacement',
          idempotencyKey: 'replacement-key',
          payload: const {'quantity': 2},
        ),
      );

      expect(result, isA<Success<OutboxOperation>>());
      final operations = (await repository.list('7')).getOrThrow();
      expect(
        operations
            .singleWhere((item) => item.operationId == 'original')
            .payload,
        const {'quantity': 1},
      );
      expect(
        operations.singleWhere((item) => item.operationId == 'original').state,
        OutboxState.conflict,
      );
      expect(
        operations
            .singleWhere((item) => item.operationId == 'replacement')
            .payload,
        const {'quantity': 2},
      );
    },
  );

  test('conflict resolution rejects reused operation id or key', () async {
    final original = _operation('original');
    await repository.enqueue(original);
    await repository.transition(
      accountId: '7',
      operationId: 'original',
      next: OutboxState.syncing,
    );
    await repository.transition(
      accountId: '7',
      operationId: 'original',
      next: OutboxState.conflict,
    );

    for (final replacement in [
      _operation('original', idempotencyKey: 'new-key'),
      _operation('new-id', idempotencyKey: original.idempotencyKey),
    ]) {
      final result = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'original',
        replacement: replacement,
      );
      expect(result, isA<FailureResult<OutboxOperation>>());
      expect(
        (result as FailureResult<OutboxOperation>).failure,
        isA<ValidationFailure>(),
      );
    }
  });

  test(
    'cancellation is account scoped and removes operation from readiness',
    () async {
      await repository.enqueue(_operation('same'));
      await repository.enqueue(_operation('other', accountId: '8'));

      final result = await repository.cancel(
        accountId: '7',
        operationId: 'same',
      );

      expect(result, isA<Success<OutboxOperation>>());
      expect((await repository.ready('7')).getOrThrow(), isEmpty);
      expect((await repository.ready('8')).getOrThrow(), hasLength(1));
    },
  );

  test(
    'hard cap is 500 per account and maps storage errors to Failure',
    () async {
      for (var index = 0; index < 500; index += 1) {
        expect(
          await repository.enqueue(_operation('operation-$index')),
          isA<Success<OutboxOperation>>(),
        );
      }

      final capped = await repository.enqueue(_operation('overflow'));
      final otherAccount = await repository.enqueue(
        _operation('allowed', accountId: '8'),
      );

      expect(capped, isA<FailureResult<OutboxOperation>>());
      expect(
        (capped as FailureResult<OutboxOperation>).failure,
        isA<StateFailure>(),
      );
      expect(otherAccount, isA<Success<OutboxOperation>>());
    },
  );

  test(
    'pruning uses terminal retention and preserves dependency audit and account isolation',
    () async {
      final old = now.subtract(const Duration(days: 31));
      clock = old;
      await repository.enqueue(
        _operation('standalone', createdAt: old, updatedAt: old),
      );
      await repository.transition(
        accountId: '7',
        operationId: 'standalone',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'standalone',
        next: OutboxState.succeeded,
      );
      await repository.enqueue(
        _operation('parent', createdAt: old, updatedAt: old),
      );
      await repository.enqueue(
        _operation('child', createdAt: old, updatedAt: old),
        dependencies: const {'parent'},
      );
      await repository.enqueue(
        _operation('other', accountId: '8', createdAt: old, updatedAt: old),
      );
      await repository.transition(
        accountId: '8',
        operationId: 'other',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '8',
        operationId: 'other',
        next: OutboxState.succeeded,
      );
      clock = now;

      final result = await repository.prune(accountId: '7');

      expect(result, isA<Success<int>>());
      expect((result as Success<int>).data, 1);
      expect(
        (await repository.list(
          '7',
        )).getOrThrow().map((item) => item.operationId),
        containsAll(['parent', 'child']),
      );
      expect((await repository.list('8')).getOrThrow(), hasLength(1));
    },
  );
}

extension<T> on Result<T> {
  T getOrThrow() =>
      when(success: (data) => data, failure: (failure) => throw failure);
}

OutboxOperation _operation(
  String id, {
  String accountId = '7',
  String? idempotencyKey,
  Map<String, Object?> payload = const {},
  OutboxState state = OutboxState.queued,
  DateTime? createdAt,
  DateTime? updatedAt,
  DateTime? nextAttemptAt,
}) {
  final timestamp = createdAt ?? DateTime.utc(2026, 7, 13);
  return OutboxOperation(
    operationId: id,
    idempotencyKey: idempotencyKey ?? 'key-$id',
    accountId: accountId,
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: payload,
    state: state,
    createdAt: timestamp,
    updatedAt: updatedAt ?? timestamp,
    confirmedAt: timestamp,
    nextAttemptAt: nextAttemptAt,
  );
}
