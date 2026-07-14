import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../services/cache_policy.dart';

typedef CacheEncoder<T> = Map<String, Object?> Function(T value);
typedef CacheDecoder<T> = T Function(Map<String, Object?> payload);

bool isCacheFallbackFailure(Failure failure) =>
    failure is NetworkFailure || failure is TransportUnknownFailure;

Future<Result<CacheSnapshot<T>>> cacheNetworkFirst<T>({
  required OfflineStore store,
  required CacheKey key,
  required CachePolicy policy,
  required DateTime Function() now,
  required Future<Result<T>> Function() loadNetwork,
  required CacheEncoder<T> encode,
  required CacheDecoder<T> decode,
}) async {
  final networkResult = await loadNetwork();
  switch (networkResult) {
    case Success<T>(:final data):
      final fetchedAt = now().toUtc();
      final record = CacheRecord(
        key: key,
        payload: encode(data),
        schemaVersion: policy.schemaVersion,
        fetchedAt: fetchedAt,
        expiresAt: policy.expiresAt(fetchedAt),
      );
      await store.writeCache(record);
      await store.enforceCacheLimit(
        accountId: key.accountId,
        warehouseId: key.warehouseId,
        namespace: key.namespace,
        maxRecords: policy.maxRecords,
      );
      return Success(
        CacheSnapshot(
          value: data,
          source: DataSourceKind.network,
          fetchedAt: record.fetchedAt,
          expiresAt: record.expiresAt,
        ),
      );
    case FailureResult<T>(failure: final failure):
      if (!isCacheFallbackFailure(failure)) {
        return FailureResult(failure);
      }
      final record = await store.readCache(
        key,
        schemaVersion: policy.schemaVersion,
      );
      if (record == null || !policy.canFallbackTo(record, now())) {
        return FailureResult(failure);
      }
      try {
        return Success(
          CacheSnapshot(
            value: decode(record.payload),
            source: DataSourceKind.cache,
            fetchedAt: record.fetchedAt,
            expiresAt: record.expiresAt,
          ),
        );
      } on Object {
        return FailureResult(failure);
      }
  }
}
