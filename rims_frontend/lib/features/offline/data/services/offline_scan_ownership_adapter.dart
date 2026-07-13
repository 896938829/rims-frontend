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
  Future<Set<String>> contentIdentitiesForAccount(String accountId) async => {
    ...await sessions.contentIdentitiesForAccount(accountId),
    ...await lookupCache.legacyContentIdentitiesForUser(accountId),
  };

  @override
  Future<int> countLookupCacheForAccount(String accountId) =>
      lookupCache.legacyCountForUser(accountId);

  @override
  Future<void> clearLookupCacheForAccount(String accountId) =>
      lookupCache.clearForUser(accountId);

  @override
  Future<void> clearLookupCacheForWarehouse(
    String accountId,
    int warehouseId,
  ) => lookupCache.clearForWarehouse(accountId, warehouseId);

  @override
  Future<void> clearForAccount(String accountId) async {
    await sessions.clearForAccount(accountId);
    await lookupCache.clearForUser(accountId);
  }

  @override
  Future<void> clearAll() async {
    await sessions.clearAll();
    await lookupCache.clearAllLegacy();
  }
}
