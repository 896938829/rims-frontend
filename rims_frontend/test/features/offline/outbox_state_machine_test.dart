import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);
  late OutboxStateMachine machine;

  setUp(() {
    machine = OutboxStateMachine(
      now: () => now,
      retryBackoff: (attempt) => Duration(minutes: attempt * 5),
    );
  });

  final legalTransitions = <OutboxState, Set<OutboxState>>{
    OutboxState.queued: {OutboxState.syncing, OutboxState.cancelled},
    OutboxState.retryableFailure: {OutboxState.syncing, OutboxState.cancelled},
    OutboxState.syncing: {
      OutboxState.succeeded,
      OutboxState.retryableFailure,
      OutboxState.conflict,
      OutboxState.permanentFailure,
      OutboxState.cancelled,
    },
    OutboxState.succeeded: {},
    OutboxState.conflict: {},
    OutboxState.permanentFailure: {},
    OutboxState.cancelled: {},
  };

  for (final current in OutboxState.values) {
    for (final next in OutboxState.values) {
      final legal = legalTransitions[current]!.contains(next);
      test('${current.wireValue} -> ${next.wireValue} is '
          '${legal ? 'allowed' : 'rejected'}', () {
        final result = machine.transition(_operation(state: current), next);

        if (legal) {
          expect(result, isA<Success<OutboxOperation>>());
          expect((result as Success<OutboxOperation>).data.state, next);
        } else {
          expect(result, isA<FailureResult<OutboxOperation>>());
          expect(
            (result as FailureResult<OutboxOperation>).failure,
            isA<StateFailure>(),
          );
        }
      });
    }
  }

  test('retryable failure schedules injected backoff without busy retry', () {
    final result = machine.transition(
      _operation(state: OutboxState.syncing, attemptCount: 2),
      OutboxState.retryableFailure,
      failure: const NetworkFailure(message: 'offline'),
    );

    final operation = (result as Success<OutboxOperation>).data;
    expect(operation.attemptCount, 3);
    expect(operation.nextAttemptAt, now.add(const Duration(minutes: 15)));
    expect(operation.lastFailureCode, 'NetworkFailure');
    expect(operation.updatedAt, now);
  });

  test('entering syncing clears a due retry schedule', () {
    final result = machine.transition(
      _operation(
        state: OutboxState.retryableFailure,
        attemptCount: 2,
        nextAttemptAt: now,
      ),
      OutboxState.syncing,
    );

    final operation = (result as Success<OutboxOperation>).data;
    expect(operation.attemptCount, 2);
    expect(operation.nextAttemptAt, isNull);
  });

  test('terminal transitions retain failure evidence and completion time', () {
    final result = machine.transition(
      _operation(state: OutboxState.syncing),
      OutboxState.permanentFailure,
      failure: const ValidationFailure(message: 'invalid'),
    );

    final operation = (result as Success<OutboxOperation>).data;
    expect(operation.lastFailureCode, 'ValidationFailure');
    expect(operation.updatedAt, now);
  });
}

OutboxOperation _operation({
  required OutboxState state,
  int attemptCount = 0,
  DateTime? nextAttemptAt,
}) {
  final createdAt = DateTime.utc(2026, 7, 13);
  return OutboxOperation(
    operationId: 'operation-1',
    idempotencyKey: 'key-1',
    accountId: '7',
    warehouseId: 11,
    kind: OutboxOperationKind.documentCreate,
    payload: const {'remark': 'original'},
    state: state,
    createdAt: createdAt,
    updatedAt: createdAt,
    confirmedAt: createdAt,
    nextAttemptAt: nextAttemptAt,
    attemptCount: attemptCount,
  );
}
