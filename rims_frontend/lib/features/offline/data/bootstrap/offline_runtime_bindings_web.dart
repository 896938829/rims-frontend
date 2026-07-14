import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/offline_ownership_service.dart';
import '../../domain/services/offline_store.dart';
import '../../domain/services/outbox_state_machine.dart';
import '../repositories/memory_outbox_repository.dart';

typedef ReadOfflineDatabaseKey = Future<String?> Function();
typedef WriteOfflineDatabaseKey = Future<void> Function(String value);

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
