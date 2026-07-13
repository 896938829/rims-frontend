import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_lookup_cache.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_session_store.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/offline/data/services/offline_scan_ownership_adapter.dart';

void main() {
  group('ScanLookupCache', () {
    test(
      'writes a versioned owner envelope with identity fields only',
      () async {
        final storage = MemoryScanStorage();
        final cache = ScanLookupCache(storage: storage);

        await cache.put(
          userId: 'user-1',
          warehouseId: 7,
          barcode: ' 690001 ',
          item: _item(productId: 11, availableQuantity: 37, stockQuantity: 41),
        );

        final raw = storage.values.values.single;
        final json = jsonDecode(raw) as Map<String, Object?>;
        final entries = json['entries']! as List<Object?>;
        final identity = (entries.single! as Map<String, Object?>)['product'];

        expect(json['schemaVersion'], ScanLookupCache.schemaVersion);
        expect(json['userId'], 'user-1');
        expect(json['warehouseId'], 7);
        expect(identity, isA<Map<String, Object?>>());
        expect((identity! as Map<String, Object?>)['productId'], 11);
        expect(raw, isNot(contains('availableQuantity')));
        expect(raw, isNot(contains('stockQuantity')));
        expect(
          await cache.get(userId: 'user-1', warehouseId: 7, barcode: '690001'),
          isNotNull,
        );
      },
    );

    test('isolates entries by user and warehouse', () async {
      final cache = ScanLookupCache(storage: MemoryScanStorage());
      await cache.put(
        userId: 'alice',
        warehouseId: 1,
        barcode: 'A',
        item: _item(productId: 1),
      );
      await cache.put(
        userId: 'alice',
        warehouseId: 2,
        barcode: 'A',
        item: _item(productId: 2),
      );
      await cache.put(
        userId: 'bob',
        warehouseId: 1,
        barcode: 'A',
        item: _item(productId: 3),
      );

      expect(
        (await cache.get(
          userId: 'alice',
          warehouseId: 1,
          barcode: 'A',
        ))!.identity.productId,
        1,
      );
      expect(
        (await cache.get(
          userId: 'alice',
          warehouseId: 2,
          barcode: 'A',
        ))!.identity.productId,
        2,
      );
      expect(
        (await cache.get(
          userId: 'bob',
          warehouseId: 1,
          barcode: 'A',
        ))!.identity.productId,
        3,
      );
    });

    test(
      'expires entries at the TTL and removes them from persistence',
      () async {
        var now = DateTime.utc(2026, 7, 13, 8);
        final storage = MemoryScanStorage();
        final cache = ScanLookupCache(
          storage: storage,
          ttl: const Duration(minutes: 10),
          now: () => now,
        );
        await cache.put(
          userId: 'user-1',
          warehouseId: 1,
          barcode: 'A',
          item: _item(productId: 1),
        );

        now = now.add(const Duration(minutes: 10));

        expect(
          await cache.get(userId: 'user-1', warehouseId: 1, barcode: 'A'),
          isNull,
        );
        final persisted =
            jsonDecode(storage.values.values.single) as Map<String, Object?>;
        expect(persisted['entries'], isEmpty);
      },
    );

    test('keeps at most 500 newest entries per user and warehouse', () async {
      var now = DateTime.utc(2026, 7, 13);
      final cache = ScanLookupCache(
        storage: MemoryScanStorage(),
        now: () => now,
      );

      for (var index = 0; index < 501; index++) {
        await cache.put(
          userId: 'user-1',
          warehouseId: 1,
          barcode: 'code-$index',
          item: _item(productId: index),
        );
        now = now.add(const Duration(seconds: 1));
      }

      expect(
        await cache.get(userId: 'user-1', warehouseId: 1, barcode: 'code-0'),
        isNull,
      );
      expect(
        await cache.get(userId: 'user-1', warehouseId: 1, barcode: 'code-500'),
        isNotNull,
      );
    });

    test('recovers from corrupt JSON and deletes the bad scope', () async {
      final storage = MemoryScanStorage();
      final key = ScanLookupCache.storageKey(userId: 'user-1', warehouseId: 1);
      storage.values[key] = '{broken';
      final cache = ScanLookupCache(storage: storage);

      expect(
        await cache.get(userId: 'user-1', warehouseId: 1, barcode: 'A'),
        isNull,
      );
      expect(storage.values, isNot(contains(key)));
    });

    test(
      'cache hits are stale and do not recreate authoritative quantities',
      () async {
        final cache = ScanLookupCache(storage: MemoryScanStorage());
        await cache.put(
          userId: 'user-1',
          warehouseId: 1,
          barcode: 'A',
          item: _item(productId: 1, availableQuantity: 9, stockQuantity: 10),
        );

        final hit = await cache.get(
          userId: 'user-1',
          warehouseId: 1,
          barcode: 'A',
        );
        final line = hit!.toScanLine();

        expect(hit.isStale, isTrue);
        expect(line.isStale, isTrue);
        expect(line.item.availableQuantity, 0);
        expect(line.item.stockQuantity, 0);
      },
    );

    test('legacy lookup migrates to Drift before deleting old key', () async {
      final legacy = MemoryScanStorage();
      await ScanLookupCache(storage: legacy).put(
        userId: 'user-1',
        warehouseId: 1,
        barcode: 'A',
        item: _item(productId: 1),
      );
      final offlineStore = MemoryOfflineStore();
      final migrated = ScanLookupCache(
        storage: legacy,
        offlineStore: offlineStore,
      );

      final lookup = await migrated.get(
        userId: 'user-1',
        warehouseId: 1,
        barcode: 'A',
      );

      expect(lookup?.identity.productId, 1);
      expect(legacy.values, isEmpty);
      expect(
        await offlineStore.readCache(
          const CacheKey(
            accountId: 'user-1',
            warehouseId: 1,
            namespace: 'scanner.lookup',
            entityKey: 'A',
          ),
        ),
        isNotNull,
      );
    });

    test('failed Drift migration preserves the legacy lookup key', () async {
      final legacy = MemoryScanStorage();
      await ScanLookupCache(storage: legacy).put(
        userId: 'user-1',
        warehouseId: 1,
        barcode: 'A',
        item: _item(productId: 1),
      );
      final migrated = ScanLookupCache(
        storage: legacy,
        offlineStore: _FailingOfflineStore(),
      );

      await expectLater(
        migrated.get(userId: 'user-1', warehouseId: 1, barcode: 'A'),
        throwsStateError,
      );
      expect(legacy.values, isNotEmpty);
    });
  });

  group('ScanSessionStore', () {
    test('restores a persisted draft after store recreation', () async {
      final storage = MemoryScanStorage();
      final first = ScanSessionStore(storage: storage);
      await first.save(
        userId: 'user-1',
        warehouseId: 3,
        session: ScanSessionSnapshot(
          mode: ScanMode.quantity,
          lines: [ScanLine(item: _item(productId: 21), quantity: 4)],
        ),
      );

      final restarted = ScanSessionStore(storage: storage);
      final restored = await restarted.restore(
        userId: 'user-1',
        warehouseId: 3,
      );

      expect(restored!.mode, ScanMode.quantity);
      expect(restored.lines.single.quantity, 4);
      expect(restored.lines.single.item.productId, 21);
      expect(restored.lines.single.isStale, isTrue);
    });

    test(
      'warehouse switching restores only the selected warehouse draft',
      () async {
        final store = ScanSessionStore(storage: MemoryScanStorage());
        await store.save(
          userId: 'user-1',
          warehouseId: 1,
          session: ScanSessionSnapshot(
            mode: ScanMode.batch,
            lines: [ScanLine(item: _item(productId: 1), quantity: 1)],
          ),
        );
        await store.save(
          userId: 'user-1',
          warehouseId: 2,
          session: ScanSessionSnapshot(
            mode: ScanMode.quantity,
            lines: [ScanLine(item: _item(productId: 2), quantity: 2)],
          ),
        );

        final warehouse2 = await store.restore(
          userId: 'user-1',
          warehouseId: 2,
        );
        final warehouse1 = await store.restore(
          userId: 'user-1',
          warehouseId: 1,
        );

        expect(warehouse2!.lines.single.item.productId, 2);
        expect(warehouse1!.lines.single.item.productId, 1);
      },
    );

    test(
      'rejects mismatched schema or ownership and removes the draft',
      () async {
        final storage = MemoryScanStorage();
        final key = ScanSessionStore.storageKey(
          userId: 'user-1',
          warehouseId: 1,
        );
        storage.values[key] = jsonEncode({
          'schemaVersion': ScanSessionStore.schemaVersion + 1,
          'userId': 'user-1',
          'warehouseId': 1,
          'mode': 'batch',
          'lines': <Object?>[],
        });

        expect(
          await ScanSessionStore(
            storage: storage,
          ).restore(userId: 'user-1', warehouseId: 1),
          isNull,
        );
        expect(storage.values, isNot(contains(key)));
      },
    );

    test('recovers from corrupt JSON', () async {
      final storage = MemoryScanStorage();
      final key = ScanSessionStore.storageKey(userId: 'user-1', warehouseId: 1);
      storage.values[key] = 'not-json';

      expect(
        await ScanSessionStore(
          storage: storage,
        ).restore(userId: 'user-1', warehouseId: 1),
        isNull,
      );
      expect(storage.values, isNot(contains(key)));
    });

    test(
      'ownership inventory counts account sessions and clears all scopes',
      () async {
        final sessions = ScanSessionStore(storage: MemoryScanStorage());
        for (final warehouseId in [1, 2]) {
          await sessions.save(
            userId: 'alice',
            warehouseId: warehouseId,
            session: ScanSessionSnapshot(
              mode: ScanMode.batch,
              lines: [
                ScanLine(item: _item(productId: warehouseId), quantity: 1),
              ],
            ),
          );
        }
        await sessions.save(
          userId: 'bob',
          warehouseId: 3,
          session: ScanSessionSnapshot(
            mode: ScanMode.batch,
            lines: [ScanLine(item: _item(productId: 3), quantity: 1)],
          ),
        );
        final ownership = sessions as OfflineOwnedScanStore;

        expect(await ownership.countForAccount('alice'), 2);
        await ownership.clearForAccount('alice');
        expect(await ownership.countForAccount('alice'), 0);
        expect(await ownership.countForAccount('bob'), 1);
        await ownership.clearAll();
        expect(await ownership.countForAccount('bob'), 0);
      },
    );

    test('logout clears all cache and drafts for that user only', () async {
      final storage = MemoryScanStorage();
      final cache = ScanLookupCache(storage: storage);
      final sessions = ScanSessionStore(storage: storage);
      for (final userId in ['alice', 'bob']) {
        await cache.put(
          userId: userId,
          warehouseId: 1,
          barcode: 'A',
          item: _item(productId: 1),
        );
        await sessions.save(
          userId: userId,
          warehouseId: 2,
          session: ScanSessionSnapshot(
            mode: ScanMode.batch,
            lines: [ScanLine(item: _item(productId: 2), quantity: 1)],
          ),
        );
      }

      await cache.clearForUser('alice');
      await sessions.clearForUser('alice');

      expect(
        await cache.get(userId: 'alice', warehouseId: 1, barcode: 'A'),
        isNull,
      );
      expect(await sessions.restore(userId: 'alice', warehouseId: 2), isNull);
      expect(
        await cache.get(userId: 'bob', warehouseId: 1, barcode: 'A'),
        isNotNull,
      );
      expect(await sessions.restore(userId: 'bob', warehouseId: 2), isNotNull);
    });

    test(
      'ownership adapter clears scan lookup and session legacy scopes together',
      () async {
        final storage = MemoryScanStorage();
        final cache = ScanLookupCache(storage: storage);
        final sessions = ScanSessionStore(storage: storage);
        await cache.put(
          userId: 'alice',
          warehouseId: 1,
          barcode: 'A',
          item: _item(productId: 1),
        );
        await sessions.save(
          userId: 'alice',
          warehouseId: 1,
          session: ScanSessionSnapshot(
            mode: ScanMode.batch,
            lines: [ScanLine(item: _item(productId: 1), quantity: 1)],
          ),
        );
        final ownership = OfflineScanOwnershipAdapter(
          sessions: sessions,
          lookupCache: cache,
        );

        await ownership.clearForAccount('alice');

        expect(await ownership.countForAccount('alice'), 0);
        expect(
          await cache.get(userId: 'alice', warehouseId: 1, barcode: 'A'),
          isNull,
        );
      },
    );
  });
}

InventoryItem _item({
  required int productId,
  int availableQuantity = 5,
  int stockQuantity = 6,
}) {
  return InventoryItem(
    id: productId + 1000,
    productId: productId,
    productName: 'Product $productId',
    sku: 'SKU-$productId',
    availableQuantity: availableQuantity,
    stockQuantity: stockQuantity,
    statusLabel: 'Enabled',
    imageUrl: '/products/$productId.png',
    alertThreshold: 2,
    status: 1,
    retailPrice: 12.5,
  );
}

final class MemoryScanStorage implements AsyncScanStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<Set<String>> keys({required String prefix}) async {
    return values.keys.where((key) => key.startsWith(prefix)).toSet();
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _FailingOfflineStore implements OfflineStore {
  @override
  Future<CacheRecord?> readCache(CacheKey key, {int? schemaVersion}) async =>
      null;

  @override
  Future<void> writeCache(CacheRecord record) async {
    throw StateError('disk full');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
