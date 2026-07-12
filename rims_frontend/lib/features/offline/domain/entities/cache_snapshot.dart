enum DataSourceKind { network, cache }

final class CacheSnapshot<T> {
  const CacheSnapshot({
    required this.value,
    required this.source,
    required this.fetchedAt,
    required this.expiresAt,
  });

  final T value;
  final DataSourceKind source;
  final DateTime fetchedAt;
  final DateTime expiresAt;

  bool isStaleAt(DateTime now) => now.isAfter(expiresAt);
}

final class CacheKey {
  const CacheKey({
    required this.accountId,
    required this.namespace,
    required this.entityKey,
    this.warehouseId,
  });

  final String accountId;
  final int? warehouseId;
  final String namespace;
  final String entityKey;
}

final class CacheRecord {
  const CacheRecord({
    required this.key,
    required this.payload,
    required this.schemaVersion,
    required this.fetchedAt,
    required this.expiresAt,
  });

  final CacheKey key;
  final Map<String, Object?> payload;
  final int schemaVersion;
  final DateTime fetchedAt;
  final DateTime expiresAt;
}
