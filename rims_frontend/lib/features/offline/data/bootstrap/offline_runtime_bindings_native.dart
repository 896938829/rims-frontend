import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/outbox_state_machine.dart';
import '../database/offline_database.dart';
import '../database/offline_database_factory.dart';
import '../repositories/drift_outbox_repository.dart';
import '../repositories/memory_outbox_repository.dart';

OutboxRepository createOutboxRepository(OfflineStore store) {
  if (store is OutboxRepositoryOwner) {
    return (store as OutboxRepositoryOwner).outboxRepository;
  }
  if (store is OfflineDatabase) {
    return DriftOutboxRepository(
      database: store,
      stateMachine: OutboxStateMachine(),
    );
  }
  return MemoryOutboxRepository(stateMachine: OutboxStateMachine());
}

OfflineDatabaseKeyManager createOfflineDatabaseKeyManager({
  required OfflineStore store,
  required ReadOfflineDatabaseKey readKey,
  required WriteOfflineDatabaseKey writeKey,
}) {
  if (store is OfflineDatabase) {
    return OfflineDatabaseKeyRotator(
      readKey: readKey,
      writeKey: writeKey,
      rekey: store.rekey,
    );
  }
  return MemoryOfflineDatabaseKeyManager();
}

OfflineOwnedFileStore createOfflineOwnedFileStore(Object store) {
  return store as OfflineOwnedFileStore;
}
