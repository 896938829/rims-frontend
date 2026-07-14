import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/outbox_state_machine.dart';
import '../repositories/memory_outbox_repository.dart';

typedef ReadOfflineDatabaseKey = Future<String?> Function();
typedef WriteOfflineDatabaseKey = Future<void> Function(String value);

const bool kSupportsOfflineFileMaintenance = false;

OutboxRepository createOutboxRepository(OfflineStore store) {
  if (store is OutboxRepositoryOwner) {
    return (store as OutboxRepositoryOwner).outboxRepository;
  }
  return MemoryOutboxRepository(stateMachine: OutboxStateMachine());
}

OfflineDatabaseKeyManager createOfflineDatabaseKeyManager({
  required OfflineStore store,
  required ReadOfflineDatabaseKey readKey,
  required WriteOfflineDatabaseKey writeKey,
}) => MemoryOfflineDatabaseKeyManager();

OfflineOwnedFileStore createOfflineOwnedFileStore(Object store) {
  return const _EmptyOfflineOwnedFileStore();
}

final class _EmptyOfflineOwnedFileStore implements OfflineOwnedFileStore {
  const _EmptyOfflineOwnedFileStore();

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async {
    return const OfflineFileOwnershipSnapshot();
  }

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {}

  @override
  Future<void> clearDownloads(String accountId) async {}

  @override
  Future<void> clearStagedTransfers(String accountId) async {}

  @override
  Future<void> clearAllFiles() async {}
}
