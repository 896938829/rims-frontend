import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);
  late Directory directory;
  late File file;
  late OfflineDatabase firstDatabase;
  late OfflineDatabase secondDatabase;
  late DriftOutboxRepository first;
  late DriftOutboxRepository second;

  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rims-outbox-race-');
    file = File('${directory.path}${Platform.pathSeparator}offline.db');
    firstDatabase = OfflineDatabase.forTesting(_executor(file));
    await firstDatabase.customSelect('SELECT 1').getSingle();
    secondDatabase = OfflineDatabase.forTesting(_executor(file));
    first = _repository(firstDatabase, now);
    second = _repository(secondDatabase, now);
  });

  tearDown(() async {
    await firstDatabase.close();
    await secondDatabase.close();
    await directory.delete(recursive: true);
  });

  test(
    'cancel and complete use CAS so exactly one terminal write wins',
    () async {
      await first.enqueue(_operation('race', now));
      await first.enqueue(
        _operation('race-child', now),
        dependencies: const {'race'},
      );
      await first.transition(
        accountId: '7',
        operationId: 'race',
        next: OutboxState.syncing,
      );

      final results = await Future.wait([
        first.cancel(accountId: '7', operationId: 'race'),
        second.transition(
          accountId: '7',
          operationId: 'race',
          next: OutboxState.succeeded,
        ),
      ]);

      expect(results.whereType<Success<OutboxOperation>>(), hasLength(1));
      final loser = results.whereType<FailureResult<OutboxOperation>>().single;
      expect(loser.failure, isA<ConflictFailure>());
      final winner = results.whereType<Success<OutboxOperation>>().single.data;
      final storedOperations =
          (await first.list('7') as Success<List<OutboxOperation>>).data;
      final stored = storedOperations.singleWhere(
        (operation) => operation.operationId == 'race',
      );
      final child = storedOperations.singleWhere(
        (operation) => operation.operationId == 'race-child',
      );
      expect(stored.state, winner.state);
      expect(stored.state, anyOf(OutboxState.cancelled, OutboxState.succeeded));
      if (winner.state == OutboxState.succeeded) {
        expect(child.state, OutboxState.queued);
        expect(
          (await first.ready('7') as Success<List<OutboxOperation>>)
              .data
              .single
              .operationId,
          'race-child',
        );
      } else {
        expect(child.state, OutboxState.cancelled);
      }
    },
  );

  test(
    'same conflict replacement request is exactly-once and idempotent',
    () async {
      await _makeConflict(first, now);
      final replacement = _operation('replacement', now);

      final results = await Future.wait([
        first.resolveConflict(
          accountId: '7',
          conflictedOperationId: 'conflict',
          replacement: replacement,
        ),
        second.resolveConflict(
          accountId: '7',
          conflictedOperationId: 'conflict',
          replacement: replacement,
        ),
      ]);

      expect(results, everyElement(isA<Success<OutboxOperation>>()));
      expect(
        results.cast<Success<OutboxOperation>>().map(
          (result) => result.data.operationId,
        ),
        everyElement('replacement'),
      );
      expect(
        results.cast<Success<OutboxOperation>>().map(
          (result) => result.data.replacementOf,
        ),
        everyElement('conflict'),
      );
      expect(
        (await first.list('7') as Success<List<OutboxOperation>>).data,
        hasLength(2),
      );
    },
  );

  test(
    'different conflict replacement keys cannot create a second write',
    () async {
      await _makeConflict(first, now);

      final results = await Future.wait([
        first.resolveConflict(
          accountId: '7',
          conflictedOperationId: 'conflict',
          replacement: _operation('replacement-a', now),
        ),
        second.resolveConflict(
          accountId: '7',
          conflictedOperationId: 'conflict',
          replacement: _operation('replacement-b', now),
        ),
      ]);

      expect(results.whereType<Success<OutboxOperation>>(), hasLength(1));
      expect(
        results.whereType<FailureResult<OutboxOperation>>().single.failure,
        isA<ConflictFailure>(),
      );
      expect(
        (await first.list('7') as Success<List<OutboxOperation>>).data,
        hasLength(2),
      );
    },
  );
}

NativeDatabase _executor(File file) {
  return NativeDatabase(
    file,
    setup: (database) {
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('PRAGMA foreign_keys = ON');
    },
  );
}

DriftOutboxRepository _repository(OfflineDatabase database, DateTime now) {
  return DriftOutboxRepository(
    database: database,
    stateMachine: OutboxStateMachine(now: () => now),
    now: () => now,
  );
}

Future<void> _makeConflict(
  DriftOutboxRepository repository,
  DateTime now,
) async {
  await repository.enqueue(_operation('conflict', now));
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
}

OutboxOperation _operation(String id, DateTime now) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: const {},
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: now,
  );
}
