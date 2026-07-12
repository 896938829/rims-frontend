import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/data/models/cache_record_model.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/data/services/cache_policy.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';

void main() {
  test('canonical JSON sorts nested object keys without reordering arrays', () {
    expect(
      CacheRecordModel.canonicalJson({
        'z': 1,
        'a': {
          'd': 4,
          'b': [
            {'y': 2, 'x': 1},
          ],
        },
      }),
      '{"a":{"b":[{"x":1,"y":2}],"d":4},"z":1}',
    );
  });

  test('default policies expose exact TTL and bounded retention', () {
    expect(CachePolicy.references.ttl, const Duration(hours: 24));
    expect(CachePolicy.reports.ttl, const Duration(hours: 6));
    expect(CachePolicy.recentDocuments.ttl, const Duration(days: 7));
    expect(CachePolicy.references.maxRecords, greaterThan(0));
    expect(
      CachePolicy.references.staleRetention,
      greaterThan(CachePolicy.references.ttl),
    );
  });

  test('policy rejects schema mismatch and records beyond retention', () {
    final now = DateTime.utc(2026, 7, 13, 12);
    final valid = CacheRecord(
      key: const CacheKey(
        accountId: '7',
        warehouseId: 11,
        namespace: 'inventory',
        entityKey: 'page=1',
      ),
      payload: const {},
      schemaVersion: CachePolicy.references.schemaVersion,
      fetchedAt: now.subtract(const Duration(days: 2)),
      expiresAt: now.subtract(const Duration(days: 1)),
    );

    expect(CachePolicy.references.canFallbackTo(valid, now), isTrue);
    expect(
      CachePolicy.references.canFallbackTo(
        CacheRecord(
          key: valid.key,
          payload: valid.payload,
          schemaVersion: valid.schemaVersion + 1,
          fetchedAt: valid.fetchedAt,
          expiresAt: valid.expiresAt,
        ),
        now,
      ),
      isFalse,
    );
    expect(
      CachePolicy.references.canFallbackTo(
        CacheRecord(
          key: valid.key,
          payload: valid.payload,
          schemaVersion: valid.schemaVersion,
          fetchedAt: now.subtract(const Duration(days: 40)),
          expiresAt: now.subtract(const Duration(days: 39)),
        ),
        now,
      ),
      isFalse,
    );
  });

  test('namespace eviction is bounded within account and warehouse', () async {
    final store = MemoryOfflineStore();
    final now = DateTime.utc(2026, 7, 13);
    for (var index = 0; index < 3; index += 1) {
      await store.writeCache(
        CacheRecord(
          key: CacheKey(
            accountId: '7',
            warehouseId: 11,
            namespace: 'inventory',
            entityKey: 'page=$index',
          ),
          payload: {'index': index},
          schemaVersion: 1,
          fetchedAt: now.add(Duration(minutes: index)),
          expiresAt: now.add(const Duration(days: 1)),
        ),
      );
    }
    await store.writeCache(
      CacheRecord(
        key: const CacheKey(
          accountId: '8',
          warehouseId: 11,
          namespace: 'inventory',
          entityKey: 'keep',
        ),
        payload: const {},
        schemaVersion: 1,
        fetchedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      ),
    );
    await store.writeCache(
      CacheRecord(
        key: const CacheKey(
          accountId: '7',
          warehouseId: 12,
          namespace: 'inventory',
          entityKey: 'keep',
        ),
        payload: const {},
        schemaVersion: 1,
        fetchedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      ),
    );

    await store.enforceCacheLimit(
      accountId: '7',
      warehouseId: 11,
      namespace: 'inventory',
      maxRecords: 2,
    );

    expect(
      await store.readCache(
        const CacheKey(
          accountId: '7',
          warehouseId: 11,
          namespace: 'inventory',
          entityKey: 'page=0',
        ),
      ),
      isNull,
    );
    expect(
      await store.readCache(
        const CacheKey(
          accountId: '8',
          warehouseId: 11,
          namespace: 'inventory',
          entityKey: 'keep',
        ),
      ),
      isNotNull,
    );
    expect(
      await store.readCache(
        const CacheKey(
          accountId: '7',
          warehouseId: 12,
          namespace: 'inventory',
          entityKey: 'keep',
        ),
      ),
      isNotNull,
    );
  });
}
