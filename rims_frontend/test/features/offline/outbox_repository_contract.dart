import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_cleanup_intent.dart';
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

    test('enqueueGraph is atomic and exact replay is idempotent', () async {
      final create = _operation('graph-create', clock.value);
      final attachment = _operation(
        'graph-attachment',
        clock.value,
        kind: OutboxOperationKind.attachmentUpload,
      );
      final graph = OutboxGraph(
        operations: [create, attachment],
        dependencies: const {
          'graph-attachment': {'graph-create'},
        },
      );

      expect(
        await repository.enqueueGraph(graph),
        isA<Success<List<OutboxOperation>>>(),
      );
      expect(
        await repository.enqueueGraph(graph),
        isA<Success<List<OutboxOperation>>>(),
      );
      expect((await repository.list('7')).successData, hasLength(2));

      final invalid = OutboxGraph(
        operations: [
          _operation('invalid-a', clock.value),
          _operation(
            'invalid-b',
            clock.value,
            idempotencyKey: 'key-invalid-a',
            kind: OutboxOperationKind.attachmentUpload,
          ),
        ],
      );
      expect(
        await repository.enqueueGraph(invalid),
        isA<FailureResult<List<OutboxOperation>>>(),
      );
      expect(
        (await repository.list('7')).successData.where(
          (operation) => operation.operationId.startsWith('invalid-'),
        ),
        isEmpty,
      );
    });

    test('dependency component query returns the complete graph', () async {
      final create = _operation('component-create', clock.value);
      final attachment = _operation(
        'component-attachment',
        clock.value,
        kind: OutboxOperationKind.attachmentUpload,
      );
      final complete = _operation(
        'component-complete',
        clock.value,
        kind: OutboxOperationKind.documentComplete,
      );
      final unrelated = _operation('component-unrelated', clock.value);
      await repository.enqueueGraph(
        OutboxGraph(
          operations: [create, attachment, complete],
          dependencies: const {
            'component-attachment': {'component-create'},
            'component-complete': {'component-attachment'},
          },
        ),
      );
      await repository.enqueue(unrelated);

      final component = await repository.loadConnectedComponent(
        accountId: '7',
        operationIds: {'component-attachment'},
      );

      expect(
        component.successData.map((item) => item.operationId),
        containsAll(<String>{
          'component-create',
          'component-attachment',
          'component-complete',
        }),
      );
      expect(
        (await repository.loadConnectedComponent(
          accountId: '7',
          operationIds: {'missing'},
        )).successData,
        isEmpty,
      );
    });

    test('success atomically persists output and cleanup intent', () async {
      final operation = _operation('output-create', clock.value);
      await repository.enqueueGraph(OutboxGraph(operations: [operation]));
      await repository.transition(
        accountId: '7',
        operationId: operation.operationId,
        next: OutboxState.syncing,
      );

      final completed = await repository.completeSuccess(
        accountId: '7',
        operationId: operation.operationId,
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
        cleanup: OutboxCleanupRequest(
          draftId: 'draft-output',
          attachmentRequestIds: ['file-output'],
        ),
      );

      expect(completed.successData.state, OutboxState.succeeded);
      expect(completed.successData.output?.data, {'documentId': 91});
      final intents = (await repository.listCleanupIntents('7')).successData;
      expect(intents, hasLength(1));
      expect(intents.single.operationId, operation.operationId);
      expect(intents.single.draftId, 'draft-output');
      expect(intents.single.attachmentRequestIds, ['file-output']);
    });

    test('success snapshots nested output and cleanup inputs', () async {
      final operation = _operation('snapshot-success', clock.value);
      await repository.enqueueGraph(OutboxGraph(operations: [operation]));
      await repository.transition(
        accountId: '7',
        operationId: operation.operationId,
        next: OutboxState.syncing,
      );
      final steps = <Object?>[
        <String, Object?>{'state': 'created'},
      ];
      final outputSource = <String, Object?>{
        'documentId': 91,
        'metadata': <String, Object?>{'steps': steps},
      };
      final cleanupIds = <String>['snapshot-file'];

      await repository.completeSuccess(
        accountId: '7',
        operationId: operation.operationId,
        output: OutboxOperationOutput(version: 1, data: outputSource),
        cleanup: OutboxCleanupRequest(
          draftId: 'snapshot-draft',
          attachmentRequestIds: cleanupIds,
        ),
      );
      (steps.single! as Map<String, Object?>)['state'] = 'mutated';
      steps.add('late');
      outputSource['documentId'] = 999;
      cleanupIds.add('late-file');

      final stored = (await repository.list('7')).successData.single;
      expect(stored.output?.data, {
        'documentId': 91,
        'metadata': {
          'steps': [
            {'state': 'created'},
          ],
        },
      });
      final metadata = stored.output!.data['metadata']! as Map<String, Object?>;
      final storedSteps = metadata['steps']! as List<Object?>;
      expect(() => metadata['late'] = true, throwsUnsupportedError);
      expect(() => storedSteps.add('late'), throwsUnsupportedError);
      expect(
        (await repository.listCleanupIntents(
          '7',
        )).successData.single.attachmentRequestIds,
        ['snapshot-file'],
      );
    });

    test('direct dependency outputs survive repository reads', () async {
      final parent = _operation('output-parent', clock.value);
      final child = _operation(
        'output-child',
        clock.value,
        kind: OutboxOperationKind.documentComplete,
      );
      await repository.enqueueGraph(
        OutboxGraph(
          operations: [parent, child],
          dependencies: const {
            'output-child': {'output-parent'},
          },
        ),
      );
      await repository.transition(
        accountId: '7',
        operationId: parent.operationId,
        next: OutboxState.syncing,
      );
      await repository.completeSuccess(
        accountId: '7',
        operationId: parent.operationId,
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
      );

      final outputs = await repository.loadDependencyOutputs(
        accountId: '7',
        operationId: child.operationId,
      );

      expect(outputs.successData.keys, {'output-parent'});
      expect(outputs.successData['output-parent']?.data['documentId'], 91);
    });

    test(
      'cleanup failure survives and completed cleanup is idempotent',
      () async {
        final operation = _operation('cleanup-retry', clock.value);
        await repository.enqueueGraph(OutboxGraph(operations: [operation]));
        await repository.transition(
          accountId: '7',
          operationId: operation.operationId,
          next: OutboxState.syncing,
        );
        await repository.completeSuccess(
          accountId: '7',
          operationId: operation.operationId,
          output: OutboxOperationOutput(version: 1, data: {}),
          cleanup: OutboxCleanupRequest(attachmentRequestIds: ['cleanup-file']),
        );

        await repository.recordCleanupFailure(
          accountId: '7',
          operationId: operation.operationId,
          failure: 'disk busy',
        );
        final failed = (await repository.listCleanupIntents(
          '7',
        )).successData.single;
        expect(failed.attemptCount, 1);
        expect(failed.lastFailure, 'disk busy');
        expect(
          (await repository.list('7')).successData.single.state,
          OutboxState.succeeded,
        );

        expect(
          await repository.completeCleanupIntent(
            accountId: '7',
            operationId: operation.operationId,
          ),
          isA<Success<void>>(),
        );
        expect(
          await repository.completeCleanupIntent(
            accountId: '7',
            operationId: operation.operationId,
          ),
          isA<Success<void>>(),
        );
        expect((await repository.listCleanupIntents('7')).successData, isEmpty);
      },
    );

    test(
      'pending cleanup intent protects succeeded operation from prune',
      () async {
        final old = initialTime.subtract(const Duration(days: 31));
        clock.value = old;
        final operation = _operation('cleanup-protected', old);
        await repository.enqueueGraph(OutboxGraph(operations: [operation]));
        await repository.transition(
          accountId: '7',
          operationId: operation.operationId,
          next: OutboxState.syncing,
        );
        await repository.completeSuccess(
          accountId: '7',
          operationId: operation.operationId,
          output: OutboxOperationOutput(version: 1, data: {}),
          cleanup: OutboxCleanupRequest(attachmentRequestIds: ['still-needed']),
        );
        clock.value = initialTime;

        expect((await repository.prune(accountId: '7')).successData, 0);
        expect((await repository.list('7')).successData, hasLength(1));
        expect(
          (await repository.listCleanupIntents('7')).successData,
          hasLength(1),
        );
      },
    );

    test('persists exact review context and rejects stale CAS', () async {
      await repository.enqueue(_operation('review-context', clock.value));
      final current = (await repository.list('7')).successData.single;
      final confirmed = await repository.confirm(
        accountId: '7',
        operationId: current.operationId,
        reviewStamp: '7\u000011\u0000document:create',
        expectedUpdatedAt: current.updatedAt,
      );

      expect(
        confirmed.successData.reviewStamp,
        '7\u000011\u0000document:create',
      );
      expect(
        (await repository.ready(
          '7',
          reviewStamp: '7\u000011\u0000document:create',
        )).successData,
        hasLength(1),
      );
      expect(
        await repository.confirm(
          accountId: '7',
          operationId: current.operationId,
          reviewStamp: '7\u000012\u0000document:create',
          expectedUpdatedAt: current.updatedAt,
        ),
        isA<FailureResult<OutboxOperation>>(),
      );
    });

    test(
      'review graph invalidation is atomic and leaves terminal history intact',
      () async {
        final create = _operation('invalidate-create', clock.value);
        final attachment = _operation(
          'invalidate-attachment',
          clock.value,
          kind: OutboxOperationKind.attachmentUpload,
        );
        final complete = _operation(
          'invalidate-complete',
          clock.value,
          kind: OutboxOperationKind.documentComplete,
        );
        await repository.enqueueGraph(
          OutboxGraph(
            operations: [create, attachment, complete],
            dependencies: const {
              'invalidate-attachment': {'invalidate-create'},
              'invalidate-complete': {'invalidate-attachment'},
            },
          ),
        );
        for (final operation in [create, attachment, complete]) {
          await repository.confirm(
            accountId: '7',
            operationId: operation.operationId,
            reviewStamp: 'review-a',
          );
        }
        await repository.transition(
          accountId: '7',
          operationId: create.operationId,
          next: OutboxState.syncing,
        );
        await repository.completeSuccess(
          accountId: '7',
          operationId: create.operationId,
          output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
        );
        final before = (await repository.list('7')).successData;
        final expected = {
          for (final operation in before)
            operation.operationId: operation.updatedAt,
        };
        final stale = Map<String, DateTime>.of(expected)
          ..[attachment.operationId] = clock.value.subtract(
            const Duration(days: 1),
          );

        final staleResult = await repository.invalidateReviewGraph(
          accountId: '7',
          expectedUpdatedAtByOperation: stale,
        );
        expect(
          staleResult,
          isA<FailureResult<List<OutboxOperation>>>().having(
            (result) => result.failure,
            'failure',
            isA<ConflictFailure>(),
          ),
        );
        expect(
          (await repository.list(
            '7',
          )).successData.map((item) => item.reviewStamp),
          everyElement('review-a'),
        );

        final invalidated = await repository.invalidateReviewGraph(
          accountId: '7',
          expectedUpdatedAtByOperation: expected,
        );

        expect(invalidated, isA<Success<List<OutboxOperation>>>());
        final after = (await repository.list('7')).successData;
        expect(
          after
              .singleWhere((item) => item.operationId == create.operationId)
              .reviewStamp,
          'review-a',
        );
        for (final id in [attachment.operationId, complete.operationId]) {
          final operation = after.singleWhere((item) => item.operationId == id);
          expect(operation.reviewStamp, isNull);
          expect(operation.confirmedAt, isNull);
        }
      },
    );

    test(
      'current CAS can replace an obsolete permission review stamp',
      () async {
        await repository.enqueue(_operation('replace-review', clock.value));
        final original = (await repository.list('7')).successData.single;
        await repository.confirm(
          accountId: '7',
          operationId: original.operationId,
          reviewStamp: '7\u000011\u0000permissions-v1',
          expectedUpdatedAt: original.updatedAt,
        );
        final reviewed = (await repository.list('7')).successData.single;

        final replaced = await repository.confirm(
          accountId: '7',
          operationId: reviewed.operationId,
          reviewStamp: '7\u000011\u0000permissions-v2',
          expectedUpdatedAt: reviewed.updatedAt,
        );

        expect(replaced, isA<Success<OutboxOperation>>());
        expect(
          replaced.successData.reviewStamp,
          '7\u000011\u0000permissions-v2',
        );
        expect(
          (await repository.ready(
            '7',
            reviewStamp: '7\u000011\u0000permissions-v1',
          )).successData,
          isEmpty,
        );
        expect(
          (await repository.ready(
            '7',
            reviewStamp: '7\u000011\u0000permissions-v2',
          )).successData,
          hasLength(1),
        );
      },
    );

    test('concurrent permission review stamps have one CAS winner', () async {
      await repository.enqueue(_operation('review-race', clock.value));
      final original = (await repository.list('7')).successData.single;

      final results = await Future.wait([
        repository.confirm(
          accountId: '7',
          operationId: original.operationId,
          reviewStamp: '7\u000011\u0000permissions-a',
          expectedUpdatedAt: original.updatedAt,
        ),
        repository.confirm(
          accountId: '7',
          operationId: original.operationId,
          reviewStamp: '7\u000011\u0000permissions-b',
          expectedUpdatedAt: original.updatedAt,
        ),
      ]);

      expect(results.whereType<Success<OutboxOperation>>(), hasLength(1));
      expect(results.whereType<FailureResult<OutboxOperation>>(), hasLength(1));
    });

    test('transactionally recovers stale syncing as unknown result', () async {
      await repository.enqueue(_operation('stale-sync', clock.value));
      await repository.transition(
        accountId: '7',
        operationId: 'stale-sync',
        next: OutboxState.syncing,
      );
      clock.value = initialTime.add(const Duration(minutes: 6));

      final recovered = await repository.recoverStaleSyncing(
        accountId: '7',
        staleBefore: clock.value.subtract(const Duration(minutes: 5)),
        operationIds: const {'stale-sync'},
      );

      expect(recovered.successData, 1);
      final operation = (await repository.list('7')).successData.single;
      expect(operation.state, OutboxState.retryableFailure);
      expect(operation.requiresStatusProbe, isTrue);
      expect(operation.syncingStartedAt, isNull);
    });

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

    test(
      'ordinary enqueue rejects public replacement ownership pollution',
      () async {
        final polluted = _operation(
          'polluted',
          clock.value,
        ).copyWith(replacementOf: 'conflict');

        final result = await repository.enqueue(polluted);

        expect(result, isA<FailureResult<OutboxOperation>>());
        expect(
          (result as FailureResult<OutboxOperation>).failure,
          isA<ValidationFailure>(),
        );
        expect((await repository.list('7')).successData, isEmpty);
      },
    );

    test(
      'conflict replacement validates initial state and ownership scope',
      () async {
        await repository.enqueue(
          _operation('validation-conflict', clock.value),
        );
        await repository.transition(
          accountId: '7',
          operationId: 'validation-conflict',
          next: OutboxState.syncing,
        );
        await repository.transition(
          accountId: '7',
          operationId: 'validation-conflict',
          next: OutboxState.conflict,
        );

        final invalidReplacements = [
          OutboxOperation(
            operationId: 'retryable-replacement',
            idempotencyKey: 'key-retryable-replacement',
            accountId: '7',
            warehouseId: 11,
            kind: OutboxOperationKind.documentCreate,
            payload: const {},
            state: OutboxState.retryableFailure,
            createdAt: clock.value,
            confirmedAt: clock.value,
          ),
          _operation('cross-account-replacement', clock.value, accountId: '8'),
          OutboxOperation(
            operationId: 'cross-warehouse-replacement',
            idempotencyKey: 'key-cross-warehouse-replacement',
            accountId: '7',
            warehouseId: 12,
            kind: OutboxOperationKind.documentCreate,
            payload: const {},
            state: OutboxState.queued,
            createdAt: clock.value,
            confirmedAt: clock.value,
          ),
          OutboxOperation(
            operationId: 'reused-key-replacement',
            idempotencyKey: 'key-validation-conflict',
            accountId: '7',
            warehouseId: 11,
            kind: OutboxOperationKind.documentCreate,
            payload: const {},
            state: OutboxState.queued,
            createdAt: clock.value,
            confirmedAt: clock.value,
          ),
        ];

        for (final replacement in invalidReplacements) {
          final result = await repository.resolveConflict(
            accountId: '7',
            conflictedOperationId: 'validation-conflict',
            replacement: replacement,
          );
          expect(result, isA<FailureResult<OutboxOperation>>());
          expect(
            (result as FailureResult<OutboxOperation>).failure,
            isA<ValidationFailure>(),
          );
        }
        final invalidDependency = await repository.resolveConflict(
          accountId: '7',
          conflictedOperationId: 'validation-conflict',
          replacement: _operation(
            'missing-dependency-replacement',
            clock.value,
          ),
          dependencies: const {'missing'},
        );
        expect(
          (invalidDependency as FailureResult<OutboxOperation>).failure,
          isA<ValidationFailure>(),
        );
        expect((await repository.list('7')).successData, hasLength(1));
      },
    );

    test('idempotent replay fingerprints sorted dependency ids', () async {
      await repository.enqueue(_operation('dep-a', clock.value));
      await repository.enqueue(_operation('dep-b', clock.value));
      await repository.enqueue(_operation('fingerprint-conflict', clock.value));
      await repository.transition(
        accountId: '7',
        operationId: 'fingerprint-conflict',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'fingerprint-conflict',
        next: OutboxState.conflict,
      );
      final replacement = _operation('fingerprint-replacement', clock.value);

      final first = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'fingerprint-conflict',
        replacement: replacement,
        dependencies: {'dep-b', 'dep-a'},
      );
      final reorderedReplay = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'fingerprint-conflict',
        replacement: replacement,
        dependencies: {'dep-a', 'dep-b'},
      );
      final differentDependencies = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'fingerprint-conflict',
        replacement: replacement,
        dependencies: const {'dep-a'},
      );

      expect(first, isA<Success<OutboxOperation>>());
      expect(reorderedReplay, isA<Success<OutboxOperation>>());
      expect(
        (differentDependencies as FailureResult<OutboxOperation>).failure,
        isA<ConflictFailure>(),
      );
      expect((await repository.list('7')).successData, hasLength(4));
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

    test(
      'payload serialization StateError is never a storage failure',
      () async {
        final invalid = OutboxOperation(
          operationId: 'invalid-json',
          idempotencyKey: 'key-invalid-json',
          accountId: '7',
          warehouseId: 11,
          kind: OutboxOperationKind.documentCreate,
          payload: {'invalid': _ThrowingJsonObject()},
          state: OutboxState.queued,
          createdAt: clock.value,
          confirmedAt: clock.value,
        );

        await expectLater(repository.enqueue(invalid), throwsStateError);

        await repository.enqueue(
          _operation('serialization-conflict', clock.value),
        );
        await repository.transition(
          accountId: '7',
          operationId: 'serialization-conflict',
          next: OutboxState.syncing,
        );
        await repository.transition(
          accountId: '7',
          operationId: 'serialization-conflict',
          next: OutboxState.conflict,
        );
        await expectLater(
          repository.resolveConflict(
            accountId: '7',
            conflictedOperationId: 'serialization-conflict',
            replacement: OutboxOperation(
              operationId: 'invalid-replacement',
              idempotencyKey: 'key-invalid-replacement',
              accountId: '7',
              warehouseId: 11,
              kind: OutboxOperationKind.documentCreate,
              payload: {'invalid': _ThrowingJsonObject()},
              state: OutboxState.queued,
              createdAt: clock.value,
              confirmedAt: clock.value,
            ),
          ),
          throwsStateError,
        );
      },
    );

    test('conflict replay serializes requested payload exactly once', () async {
      await repository.enqueue(_operation('single-json-conflict', clock.value));
      await repository.transition(
        accountId: '7',
        operationId: 'single-json-conflict',
        next: OutboxState.syncing,
      );
      await repository.transition(
        accountId: '7',
        operationId: 'single-json-conflict',
        next: OutboxState.conflict,
      );
      await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'single-json-conflict',
        replacement: OutboxOperation(
          operationId: 'single-json-replacement',
          idempotencyKey: 'key-single-json-replacement',
          accountId: '7',
          warehouseId: 11,
          kind: OutboxOperationKind.documentCreate,
          payload: const {'value': 1},
          state: OutboxState.queued,
          createdAt: clock.value,
          confirmedAt: clock.value,
        ),
      );
      final stateful = _SingleUseJsonObject();

      final replay = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'single-json-conflict',
        replacement: OutboxOperation(
          operationId: 'single-json-replacement',
          idempotencyKey: 'key-single-json-replacement',
          accountId: '7',
          warehouseId: 11,
          kind: OutboxOperationKind.documentCreate,
          payload: {'value': stateful},
          state: OutboxState.queued,
          createdAt: clock.value,
          confirmedAt: clock.value,
        ),
      );

      expect(replay, isA<Success<OutboxOperation>>());
      expect(stateful.calls, 1);
    });

    test(
      'clearAccount removes resolution graph only for its account',
      () async {
        for (final accountId in ['7', '8']) {
          final original = _operation(
            'clear-original-$accountId',
            clock.value,
            accountId: accountId,
          );
          await repository.enqueue(original);
          await repository.transition(
            accountId: accountId,
            operationId: original.operationId,
            next: OutboxState.syncing,
          );
          await repository.transition(
            accountId: accountId,
            operationId: original.operationId,
            next: OutboxState.conflict,
          );
          await repository.resolveConflict(
            accountId: accountId,
            conflictedOperationId: original.operationId,
            replacement: _operation(
              'clear-replacement-$accountId',
              clock.value,
              accountId: accountId,
            ),
          );
        }

        final cleared = await repository.clearAccount('7');

        expect(cleared, isA<Success<void>>());
        expect((await repository.list('7')).successData, isEmpty);
        expect((await repository.list('8')).successData, hasLength(2));
        final retainedReplay = await repository.resolveConflict(
          accountId: '8',
          conflictedOperationId: 'clear-original-8',
          replacement: _operation(
            'clear-replacement-8',
            clock.value,
            accountId: '8',
          ),
        );
        expect(retainedReplay, isA<Success<OutboxOperation>>());
      },
    );
  });
}

final class _ThrowingJsonObject {
  Object? toJson() => throw StateError('custom serialization failed');
}

final class _SingleUseJsonObject {
  int calls = 0;

  Object? toJson() {
    calls += 1;
    if (calls > 1) throw StateError('serialized more than once');
    return 1;
  }
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;
}

OutboxOperation _operation(
  String id,
  DateTime now, {
  String accountId = '7',
  String? idempotencyKey,
  OutboxOperationKind kind = OutboxOperationKind.documentCreate,
}) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: idempotencyKey ?? 'key-$id',
    accountId: accountId,
    warehouseId: 11,
    kind: kind,
    payload: const {},
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: now,
  );
}
