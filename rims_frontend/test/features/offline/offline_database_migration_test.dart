import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_cleanup_intent.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
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

    expect(version.read<int>('user_version'), 6);
    expect(migratedRows, hasLength(3));
    expect(
      migratedRows.every(
        (row) => row.read<int>('updated_at') == row.read<int>('created_at'),
      ),
      isTrue,
    );
    expect(foreignKeys, hasLength(2));
    expect(foreignKeysEnabled.read<int>('foreign_keys'), 1);
    await _expectLegacySyncingProbeFirst(repository, createdAt);
    expect((await repository.ready('7')).successData, isEmpty);
    final child = (await repository.list(
      '7',
    )).successData.singleWhere((operation) => operation.operationId == 'child');
    expect(child.confirmedAt, isNull);
    await repository.confirm(
      accountId: '7',
      operationId: 'child',
      reviewStamp: '7\u000011\u0000document:create',
      expectedUpdatedAt: child.updatedAt,
    );
    expect(
      (await repository.ready(
        '7',
        reviewStamp: '7\u000011\u0000document:create',
      )).successData.single.operationId,
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

    expect(version.read<int>('user_version'), 6);
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
    await _expectLegacySyncingProbeFirst(repository, createdAt);
    expect((await repository.list('7')).successData, hasLength(3));
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

      expect(version.read<int>('user_version'), 6);
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
      await _expectLegacySyncingProbeFirst(repository, createdAt);
    },
  );

  test('real v4 file adds recovery and review context columns', () async {
    final directory = await Directory.systemTemp.createTemp('rims-v4-db-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}offline.db');
    final createdAt = DateTime.utc(2026, 7, 1);
    _createV4Fixture(file.path, createdAt);

    final database = OfflineDatabase.forTesting(NativeDatabase(file));
    addTearDown(database.close);
    final version = await database
        .customSelect('PRAGMA user_version')
        .getSingle();
    final columns = await database
        .customSelect('PRAGMA table_info(outbox_operations)')
        .get();
    final legacy = await database
        .customSelect(
          'SELECT confirmed_at, review_stamp, requires_status_probe, '
          'syncing_started_at FROM outbox_operations '
          "WHERE operation_id = 'legacy-syncing'",
        )
        .getSingle();

    expect(version.read<int>('user_version'), 6);
    expect(
      columns.map((row) => row.read<String>('name')),
      containsAll([
        'review_stamp',
        'requires_status_probe',
        'syncing_started_at',
      ]),
    );
    expect(legacy.read<int?>('confirmed_at'), isNull);
    expect(legacy.read<String?>('review_stamp'), isNull);
    expect(legacy.read<int>('requires_status_probe'), 1);
    expect(legacy.read<int?>('syncing_started_at'), isNull);
    final repository = DriftOutboxRepository(
      database: database,
      stateMachine: OutboxStateMachine(now: () => createdAt),
      now: () => createdAt,
    );
    await _expectLegacySyncingProbeFirst(repository, createdAt);
  });

  test(
    'real v5 file persists v6 output and cleanup across recreation',
    () async {
      final directory = await Directory.systemTemp.createTemp('rims-v5-db-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}offline.db');
      final createdAt = DateTime.utc(2026, 7, 1);
      _createV5Fixture(file.path, createdAt);

      var database = OfflineDatabase.forTesting(NativeDatabase(file));
      var repository = DriftOutboxRepository(
        database: database,
        stateMachine: OutboxStateMachine(now: () => createdAt),
        now: () => createdAt,
      );
      final operation = _operation('v6-output', createdAt);
      await repository.enqueueGraph(OutboxGraph(operations: [operation]));
      await repository.transition(
        accountId: '7',
        operationId: operation.operationId,
        next: OutboxState.syncing,
      );
      await repository.completeSuccess(
        accountId: '7',
        operationId: operation.operationId,
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
        cleanup: OutboxCleanupRequest(
          draftId: 'draft-v6',
          attachmentRequestIds: ['file-v6'],
        ),
      );
      await database.close();

      database = OfflineDatabase.forTesting(NativeDatabase(file));
      addTearDown(database.close);
      repository = DriftOutboxRepository(
        database: database,
        stateMachine: OutboxStateMachine(now: () => createdAt),
        now: () => createdAt,
      );

      final version = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      final restored = (await repository.list('7')).successData.singleWhere(
        (item) => item.operationId == operation.operationId,
      );
      final intents = (await repository.listCleanupIntents('7')).successData;
      expect(version.read<int>('user_version'), 6);
      expect(restored.output?.data['documentId'], 91);
      expect(intents.single.draftId, 'draft-v6');
      expect(intents.single.attachmentRequestIds, ['file-v6']);
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
      insert.execute([
        'legacy-syncing',
        'key-legacy-syncing',
        'syncing',
        timestamp,
        timestamp,
      ]);
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
    database.execute('''
INSERT INTO outbox_operations (
  operation_id, idempotency_key, account_id, warehouse_id, operation_kind,
  payload, operation_state, created_at, updated_at, confirmed_at, attempt_count
) VALUES ('legacy-syncing', 'key-legacy-syncing', '7', 11,
  'document_create', '{}', 'syncing', $timestamp, NULL, $timestamp, 0)
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

void _createV4Fixture(String path, DateTime createdAt) {
  _createV3Fixture(path, createdAt);
  final database = sqlite.sqlite3.open(path);
  try {
    database.execute('''
CREATE UNIQUE INDEX outbox_operation_account_identity
ON outbox_operations (operation_id, account_id)
''');
    database.execute('''
CREATE TABLE outbox_resolutions (
  original_operation_id TEXT NOT NULL PRIMARY KEY,
  replacement_operation_id TEXT NOT NULL UNIQUE,
  account_id TEXT NOT NULL,
  dependency_fingerprint TEXT NOT NULL,
  FOREIGN KEY (original_operation_id, account_id)
    REFERENCES outbox_operations (operation_id, account_id),
  FOREIGN KEY (replacement_operation_id, account_id)
    REFERENCES outbox_operations (operation_id, account_id)
)
''');
    database.execute('''
INSERT INTO outbox_resolutions (
  original_operation_id, replacement_operation_id, account_id,
  dependency_fingerprint
) VALUES ('conflict', 'replacement', '7', '["dep-a","dep-b"]')
''');
    database.execute('DROP INDEX outbox_replacement_once');
    database.execute('PRAGMA user_version = 4');
  } finally {
    database.close();
  }
}

void _createV5Fixture(String path, DateTime createdAt) {
  _createV4Fixture(path, createdAt);
  final database = sqlite.sqlite3.open(path);
  try {
    database.execute(
      'ALTER TABLE outbox_operations ADD COLUMN review_stamp TEXT NULL',
    );
    database.execute(
      'ALTER TABLE outbox_operations ADD COLUMN requires_status_probe '
      'INTEGER NOT NULL DEFAULT 0 CHECK (requires_status_probe IN (0, 1))',
    );
    database.execute(
      'ALTER TABLE outbox_operations ADD COLUMN syncing_started_at INTEGER NULL',
    );
    database.execute('PRAGMA user_version = 5');
  } finally {
    database.close();
  }
}

Future<void> _expectLegacySyncingProbeFirst(
  DriftOutboxRepository repository,
  DateTime now,
) async {
  const context = OutboxExecutionContext(
    accountId: '7',
    warehouseId: 11,
    permissionStamp: 'document:create',
    allowedKinds: {OutboxOperationKind.documentCreate},
  );
  final migrated = (await repository.list('7')).successData.singleWhere(
    (operation) => operation.operationId == 'legacy-syncing',
  );
  expect(migrated.state, OutboxState.retryableFailure);
  expect(migrated.requiresStatusProbe, isTrue);
  expect(migrated.syncingStartedAt, isNull);
  expect(migrated.lastFailureCode, 'unknown_result');
  expect(migrated.nextAttemptAt?.isAfter(now), isFalse);
  final confirmed = await repository.confirm(
    accountId: '7',
    operationId: migrated.operationId,
    reviewStamp: context.reviewStamp,
    expectedUpdatedAt: migrated.updatedAt,
  );
  expect(confirmed, isA<Success<OutboxOperation>>());
  final events = <String>[];
  final executor = OutboxExecutor(
    repository: repository,
    networkStatusService: const _OnlineNetwork(),
    statusDataSource: _AbsentStatus(events),
    handlers: [_RecordingHandler(events)],
    contextReader: () => context,
    now: () => now,
  );

  final report = await executor.execute(
    OutboxReview(
      operationIds: const {'legacy-syncing'},
      accountId: context.accountId,
      warehouseId: context.warehouseId,
      permissionStamp: context.permissionStamp,
    ),
  );

  expect(report.succeededOperationIds, ['legacy-syncing']);
  expect(events, ['status', 'handler']);
}

final class _AbsentStatus implements OperationStatusRemoteDataSource {
  const _AbsentStatus(this.events);
  final List<String> events;

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async {
    events.add('status');
    return const FailureResult(NotFoundFailure());
  }
}

final class _RecordingHandler implements OutboxOperationHandler {
  const _RecordingHandler(this.events);
  final List<String> events;

  @override
  OutboxOperationKind get kind => OutboxOperationKind.documentCreate;

  @override
  String get statusScope => 'POST /api/v1/documents';

  @override
  Future<Result<OutboxHandlerSuccess>> execute(
    OutboxOperation operation, {
    Map<String, OutboxOperationOutput> dependencyOutputs = const {},
    OutboxHandlerExecutionContext executionContext =
        const OutboxHandlerExecutionContext.unverified(),
  }) async {
    events.add('handler');
    return Success(
      OutboxHandlerSuccess(output: OutboxOperationOutput(version: 1, data: {})),
    );
  }
}

final class _OnlineNetwork implements NetworkStatusService {
  const _OnlineNetwork();

  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  NetworkReachability get current => NetworkReachability.online;

  @override
  Future<NetworkReachability> verify() async => NetworkReachability.online;

  @override
  void markOnlineFromRequest() {}

  @override
  Future<void> dispose() async {}
}
