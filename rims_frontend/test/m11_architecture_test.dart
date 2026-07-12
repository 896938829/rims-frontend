import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';

void main() {
  test('cache snapshot records source age and expiry deterministically', () {
    final fetchedAt = DateTime.utc(2026, 7, 13, 1);
    final expiresAt = fetchedAt.add(const Duration(hours: 6));
    final snapshot = CacheSnapshot<String>(
      value: 'inventory',
      source: DataSourceKind.cache,
      fetchedAt: fetchedAt,
      expiresAt: expiresAt,
    );

    expect(snapshot.source, DataSourceKind.cache);
    expect(snapshot.isStaleAt(expiresAt), isFalse);
    expect(
      snapshot.isStaleAt(expiresAt.add(const Duration(microseconds: 1))),
      isTrue,
    );
  });

  test('network reachability has stable exhaustive states', () {
    expect(NetworkReachability.values.map((value) => value.name), [
      'offline',
      'checking',
      'online',
      'unreachable',
    ]);
  });

  test('outbox contracts preserve stable wire values and ownership', () {
    expect(OutboxState.values.map((value) => value.wireValue), [
      'queued',
      'syncing',
      'succeeded',
      'retryable_failure',
      'conflict',
      'permanent_failure',
      'cancelled',
    ]);
    expect(OutboxOperationKind.values.map((value) => value.wireValue), [
      'attachment_upload',
      'document_create',
      'document_complete',
      'stocktake_confirm',
      'stocktake_settle',
    ]);

    final operation = OutboxOperation(
      operationId: 'operation-1',
      idempotencyKey: 'request-1',
      accountId: '7',
      warehouseId: 11,
      kind: OutboxOperationKind.documentCreate,
      payload: const {'doc_type': 2},
      state: OutboxState.queued,
      createdAt: DateTime.utc(2026, 7, 13),
    );

    expect(operation.accountId, '7');
    expect(operation.warehouseId, 11);
    expect(operation.isConfirmed, isFalse);
  });

  test('offline boundaries expose storage and verified network services', () {
    expect(OfflineStore, isNotNull);
    expect(NetworkStatusService, isNotNull);
  });
}
