import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';

void main() {
  late OfflineDatabase database;

  setUp(() {
    database = OfflineDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'cache upsert is unique per schema and reads the newest schema',
    () async {
      const key = CacheKey(
        accountId: '7',
        warehouseId: 11,
        namespace: 'inventory.page',
        entityKey: 'keyword=water&page=1',
      );
      final fetchedAt = DateTime.utc(2026, 7, 13);
      await database.writeCache(
        CacheRecord(
          key: key,
          payload: const {'quantity': 2},
          schemaVersion: 1,
          fetchedAt: fetchedAt,
          expiresAt: fetchedAt.add(const Duration(hours: 24)),
        ),
      );
      await database.writeCache(
        CacheRecord(
          key: key,
          payload: const {'quantity': 3},
          schemaVersion: 1,
          fetchedAt: fetchedAt.add(const Duration(minutes: 1)),
          expiresAt: fetchedAt.add(const Duration(hours: 24, minutes: 1)),
        ),
      );
      await database.writeCache(
        CacheRecord(
          key: key,
          payload: const {
            'quantity': 4,
            'detail': {'z': 2, 'a': 1},
          },
          schemaVersion: 2,
          fetchedAt: fetchedAt.add(const Duration(minutes: 2)),
          expiresAt: fetchedAt.add(const Duration(hours: 24, minutes: 2)),
        ),
      );

      final record = await database.readCache(key);
      expect(record?.schemaVersion, 2);
      expect(record?.payload['quantity'], 4);
      expect(await database.cacheRecordCount(), 2);
      final storedPayload = await database
          .customSelect(
            'SELECT payload FROM cache_records WHERE record_schema_version = 2',
          )
          .getSingle();
      expect(
        storedPayload.read<String>('payload'),
        '{"detail":{"a":1,"z":2},"quantity":4}',
      );
    },
  );

  test('schema uses the stable physical table names', () async {
    final rows = await database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get();
    expect(
      rows.map((row) => row.read<String>('name')),
      containsAll(<String>[
        'cache_records',
        'document_drafts',
        'outbox_operations',
        'outbox_dependencies',
      ]),
    );
  });

  test('draft save replaces only the matching account owned version', () async {
    final createdAt = DateTime.utc(2026, 7, 13);
    await database.saveDraft(
      DocumentDraft(
        id: 'draft-1',
        accountId: '7',
        warehouseId: 11,
        payload: const {'remark': 'first'},
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await database.saveDraft(
      DocumentDraft(
        id: 'draft-1',
        accountId: '7',
        warehouseId: 11,
        payload: const {'remark': 'second'},
        createdAt: createdAt,
        updatedAt: createdAt.add(const Duration(minutes: 1)),
        version: 2,
      ),
    );

    final drafts = await database.listDrafts('7');
    expect(drafts, hasLength(1));
    expect(drafts.single.version, 2);
    expect(drafts.single.payload, const {'remark': 'second'});
  });

  test('dependency blocks child until parent succeeds', () async {
    final now = DateTime.utc(2026, 7, 13);
    final parent = _operation(
      'upload-1',
      now,
      OutboxOperationKind.attachmentUpload,
    );
    final child = _operation(
      'document-1',
      now,
      OutboxOperationKind.documentCreate,
    );

    await database.enqueue(parent, const {});
    await database.enqueue(child, const {'upload-1'});

    expect(
      (await database.readyOperations('7')).map((item) => item.operationId),
      ['upload-1'],
    );
    await database.transition('upload-1', OutboxState.syncing);
    await database.transition('upload-1', OutboxState.succeeded);
    expect(
      (await database.readyOperations('7')).map((item) => item.operationId),
      ['document-1'],
    );
  });

  test('state transitions reject skips and terminal replay', () async {
    final operation = _operation(
      'operation-1',
      DateTime.utc(2026, 7, 13),
      OutboxOperationKind.documentCreate,
    );
    await database.enqueue(operation, const {});

    await expectLater(
      database.transition('operation-1', OutboxState.succeeded),
      throwsStateError,
    );
    await database.transition('operation-1', OutboxState.syncing);
    await database.transition('operation-1', OutboxState.succeeded);
    await expectLater(
      database.transition('operation-1', OutboxState.syncing),
      throwsStateError,
    );
  });

  test(
    'account cleanup removes cache drafts outbox and dependencies',
    () async {
      final now = DateTime.utc(2026, 7, 13);
      await database.writeCache(
        CacheRecord(
          key: const CacheKey(
            accountId: '7',
            namespace: 'session',
            entityKey: 'me',
          ),
          payload: const {'id': 7},
          schemaVersion: 1,
          fetchedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
        ),
      );
      await database.saveDraft(
        DocumentDraft(
          id: 'draft-1',
          accountId: '7',
          warehouseId: 11,
          payload: const {},
          createdAt: now,
          updatedAt: now,
        ),
      );
      await database.enqueue(
        _operation('operation-1', now, OutboxOperationKind.documentCreate),
        const {},
      );

      await database.clearAccount('7');

      expect(await database.cacheRecordCount(), 0);
      expect(await database.listDrafts('7'), isEmpty);
      expect(await database.readyOperations('7'), isEmpty);
    },
  );

  test('enqueue rejects self and missing dependencies atomically', () async {
    final now = DateTime.utc(2026, 7, 13);
    final operation = _operation(
      'operation-1',
      now,
      OutboxOperationKind.documentCreate,
    );

    await expectLater(
      database.enqueue(operation, const {'operation-1'}),
      throwsArgumentError,
    );
    await expectLater(
      database.enqueue(operation, const {'missing-parent'}),
      throwsStateError,
    );
    expect(await database.readyOperations('7'), isEmpty);
  });

  test('enqueue enforces a hard 500 operation cap per account', () async {
    final now = DateTime.utc(2026, 7, 13);
    for (var index = 0; index < 500; index += 1) {
      await database.enqueue(
        _operation(
          'operation-$index',
          now.add(Duration(milliseconds: index)),
          OutboxOperationKind.documentCreate,
        ),
        const {},
      );
    }

    await expectLater(
      database.enqueue(
        _operation(
          'operation-501',
          now.add(const Duration(seconds: 1)),
          OutboxOperationKind.documentCreate,
        ),
        const {},
      ),
      throwsStateError,
    );
  });

  test(
    'prune removes expired cache but keeps boundary and fresh rows',
    () async {
      final now = DateTime.utc(2026, 7, 13, 12);
      for (final (entityKey, expiresAt) in [
        ('expired', now.subtract(const Duration(microseconds: 1))),
        ('boundary', now),
        ('fresh', now.add(const Duration(hours: 1))),
      ]) {
        await database.writeCache(
          CacheRecord(
            key: CacheKey(
              accountId: '7',
              namespace: 'inventory',
              entityKey: entityKey,
            ),
            payload: const {},
            schemaVersion: 1,
            fetchedAt: now.subtract(const Duration(hours: 1)),
            expiresAt: expiresAt,
          ),
        );
      }

      await database.prune(now);

      expect(await database.cacheRecordCount(), 2);
      expect(
        await database.readCache(
          const CacheKey(
            accountId: '7',
            namespace: 'inventory',
            entityKey: 'boundary',
          ),
        ),
        isNotNull,
      );
    },
  );
}

OutboxOperation _operation(String id, DateTime now, OutboxOperationKind kind) {
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: 11,
    kind: kind,
    payload: const {},
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: now,
  );
}
