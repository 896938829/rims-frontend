import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../../../core/result/failure.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/offline_content_revision.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../models/cache_record_model.dart';
import 'offline_tables.dart';

part 'offline_database.g.dart';

@DriftDatabase(
  tables: [
    OfflineCacheEntries,
    OfflineDocumentDrafts,
    OfflineOutboxOperations,
    OfflineOutboxDependencies,
    OfflineOutboxResolutions,
    OfflineOutboxCleanupIntents,
  ],
)
final class OfflineDatabase extends _$OfflineDatabase
    implements OfflineStore, OfflineOwnershipStore {
  OfflineDatabase.forTesting(super.executor);

  OfflineDatabase.native({
    required String encryptionKey,
    required String databasePath,
  }) : super(
         driftDatabase(
           name: 'rims_offline',
           native: DriftNativeOptions(
             databasePath: () async => databasePath,
             tempDirectoryPath: () async => File(databasePath).parent.path,
             setup: (database) {
               database.execute('PRAGMA key = "x\'$encryptionKey\'";');
               database.execute('PRAGMA foreign_keys = ON;');
             },
           ),
         ),
       );

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.updatedAt,
        );
      }
      if (from < 3) {
        await customStatement(
          'UPDATE outbox_operations '
          'SET updated_at = created_at WHERE updated_at IS NULL',
        );
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.replacementOf,
        );
      }
      if (from < 4) {
        await customStatement('''
CREATE UNIQUE INDEX IF NOT EXISTS outbox_operation_account_identity
ON outbox_operations (operation_id, account_id)
''');
        await migrator.createTable(offlineOutboxResolutions);
        if (from >= 3) {
          await customStatement('''
INSERT INTO outbox_resolutions (
  original_operation_id,
  replacement_operation_id,
  account_id,
  dependency_fingerprint
)
SELECT
  replacement.replacement_of,
  replacement.operation_id,
  replacement.account_id,
  COALESCE((
    SELECT '[' || group_concat(json_quote(sorted_edges.dependency_id), ',') || ']'
    FROM (
      SELECT dependency_id
      FROM outbox_dependencies
      WHERE operation_id = replacement.operation_id
      ORDER BY dependency_id
    ) AS sorted_edges
  ), '[]')
FROM outbox_operations AS replacement
JOIN outbox_operations AS original
  ON original.operation_id = replacement.replacement_of
 AND original.account_id = replacement.account_id
 AND original.operation_state = 'conflict'
WHERE replacement.replacement_of IS NOT NULL
''');
          await customStatement('''
UPDATE outbox_operations
SET replacement_of = NULL
WHERE replacement_of IS NOT NULL
  AND operation_id NOT IN (
    SELECT replacement_operation_id FROM outbox_resolutions
  )
''');
        }
      }
      if (from < 5) {
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.reviewStamp,
        );
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.requiresStatusProbe,
        );
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.syncingStartedAt,
        );
        await customStatement('''
UPDATE outbox_operations
SET operation_state = 'retryable_failure',
    updated_at = COALESCE(updated_at, created_at),
    next_attempt_at = COALESCE(updated_at, created_at),
    last_failure_code = 'unknown_result',
    requires_status_probe = 1,
    syncing_started_at = NULL
WHERE operation_state = 'syncing'
''');
        await customStatement(
          'UPDATE outbox_operations SET confirmed_at = NULL '
          'WHERE review_stamp IS NULL',
        );
      }
      if (from < 6) {
        await migrator.addColumn(
          offlineOutboxOperations,
          offlineOutboxOperations.output,
        );
        await migrator.createTable(offlineOutboxCleanupIntents);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('''
CREATE UNIQUE INDEX IF NOT EXISTS outbox_operation_account_identity
ON outbox_operations (operation_id, account_id)
''');
      await customStatement('DROP INDEX IF EXISTS outbox_replacement_once');
    },
  );

  @override
  Future<void> writeCache(CacheRecord record) async {
    await into(offlineCacheEntries).insertOnConflictUpdate(
      OfflineCacheEntriesCompanion.insert(
        cacheId: _cacheId(record.key, record.schemaVersion),
        accountId: record.key.accountId,
        warehouseId: Value(record.key.warehouseId),
        namespace: record.key.namespace,
        entityKey: record.key.entityKey,
        payload: CacheRecordModel.canonicalJson(record.payload),
        recordSchemaVersion: record.schemaVersion,
        fetchedAt: record.fetchedAt.toUtc(),
        expiresAt: record.expiresAt.toUtc(),
      ),
    );
  }

  @override
  Future<CacheRecord?> readCache(CacheKey key, {int? schemaVersion}) async {
    final query = select(offlineCacheEntries)
      ..where(
        (entry) =>
            entry.accountId.equals(key.accountId) &
            (key.warehouseId == null
                ? entry.warehouseId.isNull()
                : entry.warehouseId.equals(key.warehouseId!)) &
            entry.namespace.equals(key.namespace) &
            entry.entityKey.equals(key.entityKey) &
            (schemaVersion == null
                ? const Constant(true)
                : entry.recordSchemaVersion.equals(schemaVersion)),
      )
      ..orderBy([(entry) => OrderingTerm.desc(entry.recordSchemaVersion)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return CacheRecord(
      key: CacheKey(
        accountId: row.accountId,
        warehouseId: row.warehouseId,
        namespace: row.namespace,
        entityKey: row.entityKey,
      ),
      payload: CacheRecordModel.decodePayload(row.payload),
      schemaVersion: row.recordSchemaVersion,
      fetchedAt: row.fetchedAt,
      expiresAt: row.expiresAt,
    );
  }

  Future<int> cacheRecordCount() async {
    final count = offlineCacheEntries.cacheId.count();
    final row = await (selectOnly(
      offlineCacheEntries,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> rekey(String encryptionKey) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(encryptionKey)) {
      throw ArgumentError.value(encryptionKey.length, 'encryptionKey');
    }
    await customStatement('PRAGMA rekey = "x\'$encryptionKey\'";');
    await customSelect('PRAGMA user_version').get();
  }

  @override
  Future<void> enforceCacheLimit({
    required String accountId,
    required int? warehouseId,
    required String namespace,
    required int maxRecords,
  }) async {
    if (maxRecords < 1) {
      throw ArgumentError.value(maxRecords, 'maxRecords');
    }
    final query = select(offlineCacheEntries)
      ..where(
        (entry) =>
            entry.accountId.equals(accountId) &
            (warehouseId == null
                ? entry.warehouseId.isNull()
                : entry.warehouseId.equals(warehouseId)) &
            entry.namespace.equals(namespace),
      )
      ..orderBy([(entry) => OrderingTerm.desc(entry.fetchedAt)]);
    final rows = await query.get();
    final evictedIds = rows
        .skip(maxRecords)
        .map((entry) => entry.cacheId)
        .toList(growable: false);
    if (evictedIds.isNotEmpty) {
      await (delete(
        offlineCacheEntries,
      )..where((entry) => entry.cacheId.isIn(evictedIds))).go();
    }
  }

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) async {
    await (delete(offlineCacheEntries)..where(
          (entry) =>
              entry.accountId.equals(accountId) &
              entry.warehouseId.equals(warehouseId),
        ))
        .go();
  }

  @override
  Future<void> deleteCacheNamespace({
    required String accountId,
    required String namespace,
  }) async {
    await (delete(offlineCacheEntries)..where(
          (entry) =>
              entry.accountId.equals(accountId) &
              entry.namespace.equals(namespace),
        ))
        .go();
  }

  @override
  Future<void> saveDraft(DocumentDraft draft, {int? expectedVersion}) async {
    await transaction(() async {
      if (expectedVersion != null) {
        final existing = await (select(
          offlineDocumentDrafts,
        )..where((row) => row.draftId.equals(draft.id))).getSingleOrNull();
        if ((existing == null && expectedVersion != 0) ||
            (existing != null && existing.draftVersion != expectedVersion)) {
          throw StateError('Document draft version conflict.');
        }
      }
      await into(offlineDocumentDrafts).insertOnConflictUpdate(
        OfflineDocumentDraftsCompanion.insert(
          draftId: draft.id,
          accountId: draft.accountId,
          warehouseId: draft.warehouseId,
          payload: CacheRecordModel.canonicalJson({
            'draft_schema_version': draft.schemaVersion,
            'doc_type': draft.docType,
            'observed_role_code': draft.observedRoleCode,
            'attachment_staging_ids': draft.attachmentStagingIds,
            'intent': draft.payload,
          }),
          draftVersion: draft.version,
          createdAt: draft.createdAt.toUtc(),
          updatedAt: draft.updatedAt.toUtc(),
        ),
      );
    });
  }

  @override
  Future<List<DocumentDraft>> listDrafts(String accountId) async {
    final query = select(offlineDocumentDrafts)
      ..where((draft) => draft.accountId.equals(accountId))
      ..orderBy([(draft) => OrderingTerm.desc(draft.updatedAt)]);
    final rows = await query.get();
    return rows
        .map((row) {
          final envelope = CacheRecordModel.decodePayload(row.payload);
          final intent = envelope['intent'];
          return DocumentDraft(
            id: row.draftId,
            accountId: row.accountId,
            warehouseId: row.warehouseId,
            docType: (envelope['doc_type'] as num?)?.toInt() ?? 0,
            observedRoleCode: envelope['observed_role_code'] as String? ?? '',
            attachmentStagingIds:
                (envelope['attachment_staging_ids'] as List?)?.cast<String>() ??
                const [],
            schemaVersion:
                (envelope['draft_schema_version'] as num?)?.toInt() ?? 0,
            payload: intent is Map
                ? Map<String, Object?>.from(intent)
                : envelope,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            version: row.draftVersion,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> deleteDraft({
    required String accountId,
    required String draftId,
  }) async {
    await (delete(offlineDocumentDrafts)..where(
          (draft) =>
              draft.accountId.equals(accountId) & draft.draftId.equals(draftId),
        ))
        .go();
  }

  @override
  Future<void> pruneDrafts(DateTime updatedBefore) async {
    await (delete(offlineDocumentDrafts)..where(
          (draft) => draft.updatedAt.isSmallerThanValue(updatedBefore.toUtc()),
        ))
        .go();
  }

  @override
  Future<void> enqueue(
    OutboxOperation operation,
    Set<String> dependencies,
  ) async {
    if (operation.replacementOf != null) {
      throw ArgumentError.value(
        operation.replacementOf,
        'operation.replacementOf',
        'Replacement ownership can only be created by conflict resolution.',
      );
    }
    if (dependencies.contains(operation.operationId)) {
      throw ArgumentError.value(
        operation.operationId,
        'dependencies',
        'An operation cannot depend on itself.',
      );
    }
    await transaction(() async {
      final count = offlineOutboxOperations.operationId.count();
      final countRow =
          await (selectOnly(offlineOutboxOperations)
                ..addColumns([count])
                ..where(
                  offlineOutboxOperations.accountId.equals(operation.accountId),
                ))
              .getSingle();
      if ((countRow.read(count) ?? 0) >= 500) {
        throw StateError('The offline outbox limit is 500 operations.');
      }
      if (dependencies.isNotEmpty) {
        final parents =
            await (selectOnly(offlineOutboxOperations)
                  ..addColumns([offlineOutboxOperations.operationId])
                  ..where(
                    offlineOutboxOperations.operationId.isIn(dependencies) &
                        offlineOutboxOperations.accountId.equals(
                          operation.accountId,
                        ),
                  ))
                .get();
        if (parents.length != dependencies.length) {
          throw StateError(
            'Every dependency must exist and belong to the same account.',
          );
        }
      }
      await into(offlineOutboxOperations).insert(
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
          replacementOf: Value(operation.replacementOf),
          reviewStamp: Value(operation.reviewStamp),
          requiresStatusProbe: Value(operation.requiresStatusProbe),
          syncingStartedAt: Value(operation.syncingStartedAt?.toUtc()),
        ),
      );
      for (final dependency in dependencies) {
        await into(offlineOutboxDependencies).insert(
          OfflineOutboxDependenciesCompanion.insert(
            operationId: operation.operationId,
            dependencyId: dependency,
          ),
        );
      }
    });
  }

  @override
  Future<List<OutboxOperation>> readyOperations(String accountId) async {
    final operations =
        await (select(offlineOutboxOperations)
              ..where((operation) => operation.accountId.equals(accountId))
              ..orderBy([(operation) => OrderingTerm.asc(operation.createdAt)]))
            .get();
    final dependencies = await select(offlineOutboxDependencies).get();
    final states = {
      for (final operation in operations)
        operation.operationId: operation.operationState,
    };
    return operations
        .where((operation) {
          if (operation.operationState != OutboxState.queued.wireValue ||
              operation.confirmedAt == null) {
            return false;
          }
          final required = dependencies.where(
            (dependency) => dependency.operationId == operation.operationId,
          );
          return required.every(
            (dependency) =>
                states[dependency.dependencyId] ==
                OutboxState.succeeded.wireValue,
          );
        })
        .map(_toDomainOperation)
        .toList(growable: false);
  }

  @override
  Future<void> transition(
    String operationId,
    OutboxState next, {
    Failure? failure,
  }) async {
    final row =
        await (select(offlineOutboxOperations)
              ..where((operation) => operation.operationId.equals(operationId)))
            .getSingleOrNull();
    if (row == null) {
      throw StateError('The offline operation does not exist.');
    }
    final current = OutboxState.values.singleWhere(
      (state) => state.wireValue == row.operationState,
    );
    if (!isOutboxTransitionAllowed(current, next)) {
      throw StateError(
        'Invalid offline operation transition: ${current.wireValue} -> '
        '${next.wireValue}.',
      );
    }
    await (update(
      offlineOutboxOperations,
    )..where((operation) => operation.operationId.equals(operationId))).write(
      OfflineOutboxOperationsCompanion(
        operationState: Value(next.wireValue),
        updatedAt: Value(DateTime.now().toUtc()),
        lastFailureCode: Value(failure?.runtimeType.toString()),
      ),
    );
  }

  @override
  Future<void> clearAccount(String accountId) async {
    await clearOwnedAccount(accountId, preserveDrafts: false);
  }

  @override
  Future<OfflineStoreOwnershipSnapshot> inspectAccount(String accountId) async {
    final cacheRows = await (select(
      offlineCacheEntries,
    )..where((row) => row.accountId.equals(accountId))).get();
    final drafts = await listDrafts(accountId);
    final operations = await (select(
      offlineOutboxOperations,
    )..where((row) => row.accountId.equals(accountId))).get();
    return OfflineStoreOwnershipSnapshot(
      cacheEntries: cacheRows.length,
      drafts: drafts.length,
      outboxOperations: operations.length,
      draftAttachmentRequestIds: {
        for (final draft in drafts) ...draft.attachmentStagingIds,
      },
      contentIdentities: {
        for (final row in cacheRows)
          'cache:${row.cacheId}:${row.recordSchemaVersion}:'
              '${row.fetchedAt.toIso8601String()}:'
              '${canonicalOfflineContentDigest(jsonDecode(row.payload))}',
        for (final draft in drafts)
          'draft:${draft.id}:${draft.version}:${draft.updatedAt.toIso8601String()}:'
              '${(draft.attachmentStagingIds.toList()..sort()).join(',')}',
        for (final operation in operations)
          'outbox:${operation.operationId}:${operation.operationState}:'
              '${operation.updatedAt?.toIso8601String() ?? operation.createdAt.toIso8601String()}',
      },
    );
  }

  @override
  Future<void> clearOwnedAccount(
    String accountId, {
    required bool preserveDrafts,
  }) async {
    await transaction(() async {
      await _deleteOutboxForAccount(accountId);
      if (!preserveDrafts) {
        await (delete(
          offlineDocumentDrafts,
        )..where((draft) => draft.accountId.equals(accountId))).go();
      }
      await (delete(
        offlineCacheEntries,
      )..where((entry) => entry.accountId.equals(accountId))).go();
    });
  }

  @override
  Future<void> clearAccountCache(String accountId) async {
    await (delete(
      offlineCacheEntries,
    )..where((entry) => entry.accountId.equals(accountId))).go();
  }

  @override
  Future<void> clearAccountOfflineWork(String accountId) async {
    await transaction(() async {
      await _deleteOutboxForAccount(accountId);
      await (delete(
        offlineDocumentDrafts,
      )..where((draft) => draft.accountId.equals(accountId))).go();
    });
  }

  @override
  Future<void> invalidatePermissionScopedCache(String accountId) async {
    await (delete(offlineCacheEntries)..where(
          (entry) =>
              entry.accountId.equals(accountId) &
              entry.namespace.equals('auth.session').not(),
        ))
        .go();
  }

  @override
  Future<void> discardSessionProjection(String accountId) async {
    await (delete(offlineCacheEntries)..where(
          (entry) =>
              entry.accountId.equals(accountId) &
              entry.namespace.equals('auth.session'),
        ))
        .go();
  }

  @override
  Future<void> clearAllSensitiveData() async {
    await transaction(() async {
      await delete(offlineOutboxDependencies).go();
      await delete(offlineOutboxResolutions).go();
      await delete(offlineOutboxCleanupIntents).go();
      await delete(offlineOutboxOperations).go();
      await delete(offlineDocumentDrafts).go();
      await delete(offlineCacheEntries).go();
    });
  }

  Future<void> _deleteOutboxForAccount(String accountId) async {
    await (delete(
      offlineOutboxResolutions,
    )..where((resolution) => resolution.accountId.equals(accountId))).go();
    await (delete(
      offlineOutboxCleanupIntents,
    )..where((intent) => intent.accountId.equals(accountId))).go();
    final operationIds =
        await (selectOnly(offlineOutboxOperations)
              ..addColumns([offlineOutboxOperations.operationId])
              ..where(offlineOutboxOperations.accountId.equals(accountId)))
            .map((row) => row.read(offlineOutboxOperations.operationId)!)
            .get();
    for (final operationId in operationIds) {
      await (delete(offlineOutboxDependencies)..where(
            (dependency) =>
                dependency.operationId.equals(operationId) |
                dependency.dependencyId.equals(operationId),
          ))
          .go();
    }
    await (delete(
      offlineOutboxOperations,
    )..where((operation) => operation.accountId.equals(accountId))).go();
  }

  @override
  Future<void> prune(DateTime now) async {
    await (delete(
      offlineCacheEntries,
    )..where((entry) => entry.expiresAt.isSmallerThanValue(now))).go();
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
    );
  }
}

String _cacheId(CacheKey key, int schemaVersion) => jsonEncode([
  key.accountId,
  key.warehouseId,
  key.namespace,
  key.entityKey,
  schemaVersion,
]);
