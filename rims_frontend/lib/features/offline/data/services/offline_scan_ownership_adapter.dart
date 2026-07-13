import '../../../scanner/domain/services/scan_lookup_cache.dart';
import '../../../scanner/domain/services/scan_session_store.dart';
import '../../domain/services/offline_ownership_service.dart';

final class OfflineScanOwnershipAdapter implements OfflineOwnedScanStore {
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
