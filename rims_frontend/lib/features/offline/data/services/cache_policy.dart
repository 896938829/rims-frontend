import '../../domain/entities/cache_snapshot.dart';

final class CachePolicy {
  const CachePolicy({
    required this.ttl,
    required this.staleRetention,
    required this.maxRecords,
    required this.schemaVersion,
  });

  static const references = CachePolicy(
    ttl: Duration(hours: 24),
    staleRetention: Duration(days: 30),
    maxRecords: 200,
    schemaVersion: 1,
  );
  static const reports = CachePolicy(
    ttl: Duration(hours: 6),
    staleRetention: Duration(days: 14),
    maxRecords: 60,
    schemaVersion: 1,
  );
  static const recentDocuments = CachePolicy(
    ttl: Duration(days: 7),
    staleRetention: Duration(days: 30),
    maxRecords: 200,
    schemaVersion: 1,
  );

  final Duration ttl;
  final Duration staleRetention;
  final int maxRecords;
  final int schemaVersion;

  DateTime expiresAt(DateTime fetchedAt) => fetchedAt.toUtc().add(ttl);

  bool canFallbackTo(CacheRecord record, DateTime now) {
    if (record.schemaVersion != schemaVersion) return false;
    return !now.toUtc().isAfter(record.expiresAt.toUtc().add(staleRetention));
  }
}
