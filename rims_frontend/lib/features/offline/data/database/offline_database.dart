import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../../../core/result/failure.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/services/offline_store.dart';
import '../models/cache_record_model.dart';
import 'offline_tables.dart';

part 'offline_database.g.dart';

@DriftDatabase(
  tables: [
    OfflineCacheEntries,
    OfflineDocumentDrafts,
    OfflineOutboxOperations,
    OfflineOutboxDependencies,
  ],
)
final class OfflineDatabase extends _$OfflineDatabase implements OfflineStore {
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
  int get schemaVersion => 3;

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
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS outbox_replacement_once '
        'ON outbox_operations(replacement_of) '
        'WHERE replacement_of IS NOT NULL',
      );
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
    await transaction(() async {
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
      await (delete(
        offlineDocumentDrafts,
      )..where((draft) => draft.accountId.equals(accountId))).go();
      await (delete(
        offlineCacheEntries,
      )..where((entry) => entry.accountId.equals(accountId))).go();
    });
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
