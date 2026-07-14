import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/repositories/cache_fallback.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/data/services/cache_policy.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_write_barrier.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';

void main() {
  const key = CacheKey(
    accountId: '7',
    warehouseId: 11,
    namespace: 'inventory',
    entityKey: 'page=1',
  );
  final now = DateTime.utc(2026, 7, 13, 12);
  const policy = CachePolicy(
    ttl: Duration(hours: 1),
    staleRetention: Duration(days: 7),
    maxRecords: 2,
    schemaVersion: 3,
  );

  test('network success is returned and written atomically', () async {
    final store = MemoryOfflineStore();

    final result = await cacheNetworkFirst<int>(
      store: store,
      key: key,
      policy: policy,
      now: () => now,
      loadNetwork: () async => const Success(4),
      encode: (value) => {'value': value},
      decode: (payload) => payload['value']! as int,
    );

    final snapshot = _success(result);
    expect(snapshot.value, 4);
    expect(snapshot.source, DataSourceKind.network);
    final cached = await store.readCache(key, schemaVersion: 3);
    expect(cached?.payload, const {'value': 4});
    expect(cached?.expiresAt, now.add(const Duration(hours: 1)));
  });

  test('network success survives a logout cache-write barrier', () async {
    final rawStore = MemoryOfflineStore();
    final barrier = OfflineWriteBarrier();
    final store = WriteBarrierOfflineStore(
      delegate: rawStore,
      barrier: barrier,
    );
    final block = barrier.blockMutations(
      const OfflineMutationScope.account('7'),
    );
    addTearDown(block.release);

    final result = await cacheNetworkFirst<int>(
      store: store,
      key: key,
      policy: policy,
      now: () => now,
      loadNetwork: () async => const Success(4),
      encode: (value) => {'value': value},
      decode: (payload) => payload['value']! as int,
    );

    final snapshot = _success(result);
    expect(snapshot.value, 4);
    expect(snapshot.source, DataSourceKind.network);
    expect(await rawStore.readCache(key, schemaVersion: 3), isNull);
  });

  test(
    'network failure returns stale cache with explicit source and age',
    () async {
      final store = MemoryOfflineStore();
      await store.writeCache(
        CacheRecord(
          key: key,
          payload: const {'value': 2},
          schemaVersion: 3,
          fetchedAt: now.subtract(const Duration(hours: 2)),
          expiresAt: now.subtract(const Duration(hours: 1)),
        ),
      );

      final result = await cacheNetworkFirst<int>(
        store: store,
        key: key,
        policy: policy,
        now: () => now,
        loadNetwork: () async =>
            const FailureResult(NetworkFailure(message: 'timeout')),
        encode: (value) => {'value': value},
        decode: (payload) => payload['value']! as int,
      );

      final snapshot = _success(result);
      expect(snapshot.value, 2);
      expect(snapshot.source, DataSourceKind.cache);
      expect(snapshot.isStaleAt(now), isTrue);
      expect(snapshot.fetchedAt, now.subtract(const Duration(hours: 2)));
    },
  );

  test('unknown read transport result falls back to retained cache', () async {
    final store = MemoryOfflineStore();
    await store.writeCache(
      CacheRecord(
        key: key,
        payload: const {'value': 2},
        schemaVersion: 3,
        fetchedAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
      ),
    );

    final result = await cacheNetworkFirst<int>(
      store: store,
      key: key,
      policy: policy,
      now: () => now,
      loadNetwork: () async => const FailureResult(
        TransportUnknownFailure(message: 'connection closed'),
      ),
      encode: (value) => {'value': value},
      decode: (payload) => payload['value']! as int,
    );

    final snapshot = _success(result);
    expect(snapshot.value, 2);
    expect(snapshot.source, DataSourceKind.cache);
  });

  test(
    'retention expiry and schema mismatch preserve network failure',
    () async {
      for (final record in [
        CacheRecord(
          key: key,
          payload: const {'value': 2},
          schemaVersion: 2,
          fetchedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
        ),
        CacheRecord(
          key: key,
          payload: const {'value': 3},
          schemaVersion: 3,
          fetchedAt: now.subtract(const Duration(days: 9)),
          expiresAt: now.subtract(const Duration(days: 8)),
        ),
      ]) {
        final store = MemoryOfflineStore();
        await store.writeCache(record);
        final result = await _networkFailure(store, key, policy, now);
        expect(result, isA<FailureResult<CacheSnapshot<int>>>());
      }
    },
  );

  test(
    'business and authorization failures never fall back to cache',
    () async {
      for (final failure in <Failure>[
        const AuthenticationFailure(),
        const AuthorizationFailure(),
        const ValidationFailure(),
        const ConflictFailure(),
        const ServerFailure(),
      ]) {
        final store = MemoryOfflineStore();
        await store.writeCache(
          CacheRecord(
            key: key,
            payload: const {'value': 2},
            schemaVersion: 3,
            fetchedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        );
        final result = await cacheNetworkFirst<int>(
          store: store,
          key: key,
          policy: policy,
          now: () => now,
          loadNetwork: () async => FailureResult(failure),
          encode: (value) => {'value': value},
          decode: (payload) => payload['value']! as int,
        );

        expect(result, isA<FailureResult<CacheSnapshot<int>>>());
        expect((result as FailureResult<CacheSnapshot<int>>).failure, failure);
      }
    },
  );
}

Future<Result<CacheSnapshot<int>>> _networkFailure(
  MemoryOfflineStore store,
  CacheKey key,
  CachePolicy policy,
  DateTime now,
) {
  return cacheNetworkFirst<int>(
    store: store,
    key: key,
    policy: policy,
    now: () => now,
    loadNetwork: () async =>
        const FailureResult(NetworkFailure(message: 'offline')),
    encode: (value) => {'value': value},
    decode: (payload) => payload['value']! as int,
  );
}

T _success<T>(Result<T> result) {
  return result.when(
    success: (data) => data,
    failure: (failure) => throw TestFailure('Expected success: $failure'),
  );
}
