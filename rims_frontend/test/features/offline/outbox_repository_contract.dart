import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';

final class OutboxTestClock {
  OutboxTestClock(this.value);

  DateTime value;

  DateTime call() => value;
}

final class OutboxRepositoryHarness {
  const OutboxRepositoryHarness({
    required this.repository,
    required this.close,
  });

  final OutboxRepository repository;
  final Future<void> Function() close;
}

typedef OutboxHarnessFactory =
    Future<OutboxRepositoryHarness> Function(OutboxTestClock clock);

void runOutboxRepositoryContract(String name, OutboxHarnessFactory create) {
  group('$name outbox contract', () {
    final initialTime = DateTime.utc(2026, 7, 13, 12);
    late OutboxTestClock clock;
    late OutboxRepositoryHarness harness;
    late OutboxRepository repository;

    setUp(() async {
      clock = OutboxTestClock(initialTime);
      harness = await create(clock);
      repository = harness.repository;
    });

    tearDown(() => harness.close());

    test('retry readiness honors attempt and injected backoff', () async {
      await repository.enqueue(_operation('retry', clock.value));
      await repository.transition(
        accountId: '7',
        operationId: 'retry',
        next: OutboxState.syncing,
      );
      final retried = await repository.transition(
        accountId: '7',
        operationId: 'retry',
        next: OutboxState.retryableFailure,
        failure: const NetworkFailure(),
      );

      final operation = (retried as Success<OutboxOperation>).data;
      expect(operation.attemptCount, 1);
      expect(
        operation.nextAttemptAt,
        initialTime.add(const Duration(minutes: 1)),
      );
      expect((await repository.ready('7')).successData, isEmpty);

      clock.value = initialTime.add(const Duration(minutes: 1));
      expect(
        (await repository.ready('7')).successData.single.operationId,
        'retry',
      );
    });

    test('dependency terminal failure propagates to descendants', () async {
      await repository.enqueue(_operation('parent', clock.value));
      await repository.enqueue(
        _operation('child', clock.value),
        dependencies: const {'parent'},
      );
      await repository.transition(
        accountId: '7',
        operationId: 'parent',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'parent',
        next: OutboxState.permanentFailure,
      );

      final child = (await repository.list('7')).successData.singleWhere(
        (operation) => operation.operationId == 'child',
      );
      expect(child.state, OutboxState.cancelled);
      expect(child.lastFailureCode, 'dependency_failed');
    });

    test(
      'cap counts active work and terminal history does not block',
      () async {
        for (var index = 0; index < 500; index += 1) {
          expect(
            await repository.enqueue(_operation('cap-$index', clock.value)),
            isA<Success<OutboxOperation>>(),
          );
        }
        expect(
          (await repository.enqueue(_operation('overflow', clock.value))
                  as FailureResult<OutboxOperation>)
              .failure,
          isA<StateFailure>(),
        );
        await repository.cancel(accountId: '7', operationId: 'cap-0');
        expect(
          await repository.enqueue(_operation('after-terminal', clock.value)),
          isA<Success<OutboxOperation>>(),
        );
      },
    );

    test('cancel removes only the owned operation from readiness', () async {
      await repository.enqueue(_operation('owned', clock.value));
      await repository.enqueue(
        _operation('other', clock.value, accountId: '8'),
      );

      await repository.cancel(accountId: '7', operationId: 'owned');

      expect((await repository.ready('7')).successData, isEmpty);
      expect((await repository.ready('8')).successData, hasLength(1));
    });

    test(
      'prune removes expired succeeded parent without changing child readiness',
      () async {
        final old = initialTime.subtract(const Duration(days: 31));
        clock.value = old;
        await repository.enqueue(_operation('old-parent', old));
        await repository.transition(
          accountId: '7',
          operationId: 'old-parent',
          next: OutboxState.syncing,
        );
        await repository.transition(
          accountId: '7',
          operationId: 'old-parent',
          next: OutboxState.succeeded,
        );
        await repository.enqueue(
          _operation('active-child', old),
          dependencies: const {'old-parent'},
        );
        clock.value = initialTime;

        expect(
          (await repository.ready('7')).successData.single.operationId,
          'active-child',
        );
        expect((await repository.prune(accountId: '7')).successData, 1);
        expect(
          (await repository.ready('7')).successData.single.operationId,
          'active-child',
        );
        expect(
          (await repository.list('7')).successData.single.operationId,
          'active-child',
        );
      },
    );

    test(
      'continuously appended chain prunes old prefix and stays bounded',
      () async {
        final old = initialTime.subtract(const Duration(days: 31));
        clock.value = old;
        String? parent;
        for (var index = 0; index < 40; index += 1) {
          final id = 'chain-$index';
          await repository.enqueue(
            _operation(id, old),
            dependencies: parent == null ? const {} : {parent},
          );
          await repository.transition(
            accountId: '7',
            operationId: id,
            next: OutboxState.syncing,
          );
          await repository.transition(
            accountId: '7',
            operationId: id,
            next: OutboxState.succeeded,
          );
          parent = id;
        }
        await repository.enqueue(
          _operation('chain-active', old),
          dependencies: {parent!},
        );
        clock.value = initialTime;

        expect((await repository.prune(accountId: '7')).successData, 40);
        expect((await repository.list('7')).successData, hasLength(1));
        expect(
          (await repository.ready('7')).successData.single.operationId,
          'chain-active',
        );
      },
    );

    test(
      'fork prunes satisfied old branches without pinning active leaf',
      () async {
        final old = initialTime.subtract(const Duration(days: 31));
        clock.value = old;
        for (final (id, parents) in [
          ('fork-root', const <String>{}),
          ('fork-left', const {'fork-root'}),
          ('fork-right', const {'fork-root'}),
        ]) {
          await repository.enqueue(_operation(id, old), dependencies: parents);
          await repository.transition(
            accountId: '7',
            operationId: id,
            next: OutboxState.syncing,
          );
          await repository.transition(
            accountId: '7',
            operationId: id,
            next: OutboxState.succeeded,
          );
        }
        await repository.enqueue(
          _operation('fork-active', old),
          dependencies: const {'fork-left', 'fork-right'},
        );
        clock.value = initialTime;

        expect((await repository.prune(accountId: '7')).successData, 3);
        expect((await repository.list('7')).successData, hasLength(1));
        expect(
          (await repository.ready('7')).successData.single.operationId,
          'fork-active',
        );
      },
    );

    test(
      'failed terminal graph prunes only after propagation completes',
      () async {
        final old = initialTime.subtract(const Duration(days: 31));
        clock.value = old;
        await repository.enqueue(_operation('failed-parent', old));
        await repository.enqueue(
          _operation('failed-child', old),
          dependencies: const {'failed-parent'},
        );
        await repository.transition(
          accountId: '7',
          operationId: 'failed-parent',
          next: OutboxState.syncing,
        );
        await repository.transition(
          accountId: '7',
          operationId: 'failed-parent',
          next: OutboxState.permanentFailure,
        );
        expect(
          (await repository.list('7')).successData
              .singleWhere(
                (operation) => operation.operationId == 'failed-child',
              )
              .state,
          OutboxState.cancelled,
        );
        clock.value = initialTime;

        expect((await repository.prune(accountId: '7')).successData, 2);
        expect((await repository.list('7')).successData, isEmpty);
      },
    );

    test('conflict replacement is idempotent and exactly-once', () async {
      await repository.enqueue(_operation('conflict', clock.value));
      await repository.transition(
        accountId: '7',
        operationId: 'conflict',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'conflict',
        next: OutboxState.conflict,
      );
      final replacement = _operation('replacement', clock.value);

      final first = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'conflict',
        replacement: replacement,
      );
      final replay = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'conflict',
        replacement: replacement,
      );
      final other = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'conflict',
        replacement: _operation('other-replacement', clock.value),
      );

      expect(first, isA<Success<OutboxOperation>>());
      expect(replay, isA<Success<OutboxOperation>>());
      expect(
        (other as FailureResult<OutboxOperation>).failure,
        isA<ConflictFailure>(),
      );
      expect((await repository.list('7')).successData, hasLength(2));
    });

    test('enqueue keeps a recursive immutable payload snapshot', () async {
      final line = <String, Object?>{'quantity': 1};
      final lines = <Object?>[line];
      final payload = <String, Object?>{'lines': lines};
      final operation = OutboxOperation(
        operationId: 'snapshot',
        idempotencyKey: 'key-snapshot',
        accountId: '7',
        warehouseId: 11,
        kind: OutboxOperationKind.documentCreate,
        payload: payload,
        state: OutboxState.queued,
        createdAt: clock.value,
        confirmedAt: clock.value,
      );
      final copied = operation.copyWith(state: OutboxState.queued);

      line['quantity'] = 99;
      lines.add(const {'quantity': 2});
      payload['extra'] = true;
      await repository.enqueue(operation);
      line['quantity'] = 100;

      final stored = (await repository.list('7')).successData.single;
      expect(stored.payload, const {
        'lines': [
          {'quantity': 1},
        ],
      });
      expect(copied.payload, stored.payload);
      expect(identical(copied.payload, operation.payload), isFalse);
      expect(
        identical(copied.payload['lines'], operation.payload['lines']),
        isFalse,
      );
      expect(
        () => (stored.payload['lines']! as List<Object?>).add(null),
        throwsUnsupportedError,
      );
      expect(
        () =>
            ((stored.payload['lines']! as List<Object?>).single
                    as Map<String, Object?>)['quantity'] =
                2,
        throwsUnsupportedError,
      );
    });
  });
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;
}

OutboxOperation _operation(String id, DateTime now, {String accountId = '7'}) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: accountId,
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: const {},
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: now,
  );
}
