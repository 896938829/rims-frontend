import 'package:drift/native.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_outbox_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

import 'outbox_repository_contract.dart';

void main() {
  runOutboxRepositoryContract('Drift', (clock) async {
    final database = OfflineDatabase.forTesting(NativeDatabase.memory());
    return OutboxRepositoryHarness(
      repository: DriftOutboxRepository(
        database: database,
        stateMachine: OutboxStateMachine(
          now: clock.call,
          retryBackoff: (attempt) => Duration(minutes: attempt),
        ),
        now: clock.call,
      ),
      close: database.close,
    );
  });

  runOutboxRepositoryContract('Memory', (clock) async {
    return OutboxRepositoryHarness(
      repository: MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(
          now: clock.call,
          retryBackoff: (attempt) => Duration(minutes: attempt),
        ),
        now: clock.call,
      ),
      close: () async {},
    );
  });
}
