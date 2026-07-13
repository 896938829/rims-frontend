import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('real v1 file migrates outbox graph and remains writable', () async {
    final directory = await Directory.systemTemp.createTemp('rims-v1-db-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}offline.db');
    final createdAt = DateTime.utc(2026, 7, 1);
    _createV1Fixture(file.path, createdAt);

    final database = OfflineDatabase.forTesting(NativeDatabase(file));
    addTearDown(database.close);
    final repository = DriftOutboxRepository(
      database: database,
      stateMachine: OutboxStateMachine(now: () => createdAt),
      now: () => createdAt,
    );

    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    final migratedRows = await database
        .customSelect(
          'SELECT operation_id, created_at, updated_at '
          'FROM outbox_operations ORDER BY operation_id',
        )
        .get();
    final foreignKeys = await database
        .customSelect('PRAGMA foreign_key_list(outbox_dependencies)')
        .get();
    final foreignKeysEnabled = await database
        .customSelect('PRAGMA foreign_keys')
        .getSingle();

    expect(version.read<int>('user_version'), 2);
    expect(migratedRows, hasLength(2));
    expect(
      migratedRows.every(
        (row) => row.read<int>('updated_at') == row.read<int>('created_at'),
      ),
      isTrue,
    );
    expect(foreignKeys, hasLength(2));
    expect(foreignKeysEnabled.read<int>('foreign_keys'), 1);
    expect(
      (await repository.ready('7')).successData.single.operationId,
      'child',
    );

    expect(
      await repository.transition(
        accountId: '7',
        operationId: 'child',
        next: OutboxState.syncing,
      ),
      isA<Success<OutboxOperation>>(),
    );
    expect(
      await repository.transition(
        accountId: '7',
        operationId: 'child',
        next: OutboxState.succeeded,
      ),
      isA<Success<OutboxOperation>>(),
    );
    expect(
      await repository.enqueue(
        _operation('new-operation', createdAt),
        dependencies: const {'child'},
      ),
      isA<Success<OutboxOperation>>(),
    );
    expect(
      (await repository.ready('7')).successData.single.operationId,
      'new-operation',
    );
  });
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;
}

OutboxOperation _operation(String id, DateTime createdAt) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: const {},
    state: OutboxState.queued,
    createdAt: createdAt,
    confirmedAt: createdAt,
  );
}

void _createV1Fixture(String path, DateTime createdAt) {
  final database = sqlite.sqlite3.open(path);
  try {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute('''
CREATE TABLE cache_records (
  cache_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL,
  warehouse_id INTEGER NULL,
  namespace TEXT NOT NULL,
  entity_key TEXT NOT NULL,
  payload TEXT NOT NULL,
  record_schema_version INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
)
''');
    database.execute('''
CREATE TABLE document_drafts (
  draft_id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL,
  warehouse_id INTEGER NOT NULL,
  payload TEXT NOT NULL,
  draft_version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
    database.execute('''
CREATE TABLE outbox_operations (
  operation_id TEXT NOT NULL PRIMARY KEY,
  idempotency_key TEXT NOT NULL,
  account_id TEXT NOT NULL,
  warehouse_id INTEGER NOT NULL,
  operation_kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  operation_state TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  confirmed_at INTEGER NULL,
  next_attempt_at INTEGER NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_failure_code TEXT NULL,
  UNIQUE (account_id, idempotency_key)
)
''');
    database.execute('''
CREATE TABLE outbox_dependencies (
  operation_id TEXT NOT NULL REFERENCES outbox_operations(operation_id)
    ON DELETE CASCADE,
  dependency_id TEXT NOT NULL REFERENCES outbox_operations(operation_id)
    ON DELETE CASCADE,
  PRIMARY KEY (operation_id, dependency_id)
)
''');
    final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;
    final insert = database.prepare('''
INSERT INTO outbox_operations (
  operation_id, idempotency_key, account_id, warehouse_id, operation_kind,
  payload, operation_state, created_at, confirmed_at, attempt_count
) VALUES (?, ?, '7', 11, 'document_create', '{}', ?, ?, ?, 0)
''');
    try {
      insert.execute([
        'parent',
        'key-parent',
        'succeeded',
        timestamp,
        timestamp,
      ]);
      insert.execute(['child', 'key-child', 'queued', timestamp, timestamp]);
    } finally {
      insert.close();
    }
    database.execute(
      "INSERT INTO outbox_dependencies (operation_id, dependency_id) "
      "VALUES ('child', 'parent')",
    );
    database.execute('PRAGMA user_version = 1');
  } finally {
    database.close();
  }
}
