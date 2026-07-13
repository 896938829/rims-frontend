import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
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

    expect(version.read<int>('user_version'), 4);
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

  test('real v2 file adds unique conflict replacement ownership', () async {
    final directory = await Directory.systemTemp.createTemp('rims-v2-db-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}offline.db');
    final createdAt = DateTime.utc(2026, 7, 1);
    _createV2Fixture(file.path, createdAt);

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
    final columns = await database
        .customSelect('PRAGMA table_info(outbox_operations)')
        .get();
    final indexes = await database
        .customSelect('PRAGMA index_list(outbox_operations)')
        .get();
    final migratedConflict = await database
        .customSelect(
          "SELECT created_at, updated_at FROM outbox_operations "
          "WHERE operation_id = 'conflict'",
        )
        .getSingle();
    final replacement = _operation('replacement', createdAt);

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

    expect(version.read<int>('user_version'), 4);
    expect(
      columns.map((row) => row.read<String>('name')),
      contains('replacement_of'),
    );
    expect(
      indexes.map((row) => row.read<String>('name')),
      isNot(contains('outbox_replacement_once')),
    );
    expect(
      migratedConflict.read<int>('updated_at'),
      migratedConflict.read<int>('created_at'),
    );
    expect(first, isA<Success<OutboxOperation>>());
    expect(replay, isA<Success<OutboxOperation>>());
    expect((await repository.list('7')).successData, hasLength(2));
  });

  test(
    'real v3 file migrates replacement ownership and dependency fingerprint',
    () async {
      final directory = await Directory.systemTemp.createTemp('rims-v3-db-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}offline.db');
      final createdAt = DateTime.utc(2026, 7, 1);
      _createV3Fixture(file.path, createdAt);

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
      final resolution = await database
          .customSelect('SELECT * FROM outbox_resolutions')
          .getSingle();
      final foreignKeys = await database
          .customSelect('PRAGMA foreign_key_list(outbox_resolutions)')
          .get();
      final indexes = await database
          .customSelect('PRAGMA index_list(outbox_operations)')
          .get();
      final replacement = _operation('replacement', createdAt);

      final replay = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'conflict',
        replacement: replacement,
        dependencies: {'dep-b', 'dep-a'},
      );
      final changedDependencies = await repository.resolveConflict(
        accountId: '7',
        conflictedOperationId: 'conflict',
        replacement: replacement,
        dependencies: const {'dep-a'},
      );

      expect(version.read<int>('user_version'), 4);
      expect(resolution.read<String>('original_operation_id'), 'conflict');
      expect(
        resolution.read<String>('replacement_operation_id'),
        'replacement',
      );
      expect(resolution.read<String>('account_id'), '7');
      expect(
        resolution.read<String>('dependency_fingerprint'),
        '["dep-a","dep-b"]',
      );
      expect(foreignKeys, hasLength(4));
      expect(
        indexes.map((row) => row.read<String>('name')),
        isNot(contains('outbox_replacement_once')),
      );
      expect(replay, isA<Success<OutboxOperation>>());
      expect(
        (changedDependencies as FailureResult<OutboxOperation>).failure,
        isA<ConflictFailure>(),
      );
    },
  );
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

void _createV2Fixture(String path, DateTime createdAt) {
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
  updated_at INTEGER NULL,
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
    database.execute('''
INSERT INTO outbox_operations (
  operation_id, idempotency_key, account_id, warehouse_id, operation_kind,
  payload, operation_state, created_at, updated_at, confirmed_at, attempt_count
) VALUES ('conflict', 'key-conflict', '7', 11, 'document_create', '{}',
  'conflict', $timestamp, NULL, $timestamp, 0)
''');
    database.execute('PRAGMA user_version = 2');
  } finally {
    database.close();
  }
}

void _createV3Fixture(String path, DateTime createdAt) {
  _createV2Fixture(path, createdAt);
  final database = sqlite.sqlite3.open(path);
  try {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute(
      'ALTER TABLE outbox_operations ADD COLUMN replacement_of TEXT NULL',
    );
    database.execute(
      'CREATE UNIQUE INDEX outbox_replacement_once '
      'ON outbox_operations(replacement_of) '
      'WHERE replacement_of IS NOT NULL',
    );
    final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;
    for (final id in ['dep-a', 'dep-b']) {
      database.execute('''
INSERT INTO outbox_operations (
  operation_id, idempotency_key, account_id, warehouse_id, operation_kind,
  payload, operation_state, created_at, updated_at, confirmed_at,
  attempt_count, replacement_of
) VALUES ('$id', 'key-$id', '7', 11, 'document_create', '{}', 'succeeded',
  $timestamp, $timestamp, $timestamp, 0, NULL)
''');
    }
    database.execute('''
INSERT INTO outbox_operations (
  operation_id, idempotency_key, account_id, warehouse_id, operation_kind,
  payload, operation_state, created_at, updated_at, confirmed_at,
  attempt_count, replacement_of
) VALUES ('replacement', 'key-replacement', '7', 11, 'document_create', '{}',
  'queued', $timestamp, $timestamp, $timestamp, 0, 'conflict')
''');
    database.execute(
      "INSERT INTO outbox_dependencies (operation_id, dependency_id) VALUES "
      "('replacement', 'dep-b'), ('replacement', 'dep-a')",
    );
    database.execute('PRAGMA user_version = 3');
  } finally {
    database.close();
  }
}
