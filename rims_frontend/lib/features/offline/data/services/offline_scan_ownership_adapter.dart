import '../../../scanner/domain/services/scan_lookup_cache.dart';
import '../../../scanner/domain/services/scan_session_store.dart';
import '../../domain/services/offline_ownership_service.dart';

final class OfflineScanOwnershipAdapter
    implements
        OfflineOwnedScanStore,
        OfflineScanOwnershipInspector,
        OfflineLookupOwnershipStore {
  const OfflineScanOwnershipAdapter({
    required this.sessions,
    required this.lookupCache,
  });

  final ScanSessionStore sessions;
  final ScanLookupCache lookupCache;

  @override
  Future<int> countForAccount(String accountId) {
    return sessions.countForAccount(accountId);
  }

  @override
  Future<Set<String>> sessionContentIdentitiesForAccount(String accountId) =>
      sessions.sessionContentIdentitiesForAccount(accountId);

  @override
  Future<int> countLookupCacheForAccount(String accountId) =>
      lookupCache.legacyCountForUser(accountId);

  @override
  Future<Set<String>> lookupContentIdentitiesForAccount(String accountId) =>
      lookupCache.legacyContentIdentitiesForUser(accountId);

  @override
  Future<void> clearLookupCacheForAccount(String accountId) =>
      lookupCache.clearForUser(accountId);

  @override
  Future<void> clearLookupCacheForWarehouse(
    String accountId,
    int warehouseId,
  ) => lookupCache.clearForWarehouse(accountId, warehouseId);

  @override
  Future<void> clearSessionsForAccount(String accountId) =>
      sessions.clearSessionsForAccount(accountId);

  @override
  Future<void> clearAllSessions() => sessions.clearAllSessions();

  @override
  Future<void> clearAllLookupCaches() => lookupCache.clearAllLegacy();
}
