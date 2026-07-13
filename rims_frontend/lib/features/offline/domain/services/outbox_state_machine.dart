import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../entities/outbox_operation.dart';

typedef RetryBackoff = Duration Function(int attemptCount);

final class OutboxStateMachine {
  OutboxStateMachine({DateTime Function()? now, RetryBackoff? retryBackoff})
    : now = now ?? DateTime.now,
      retryBackoff = retryBackoff ?? _defaultBackoff;

  final DateTime Function() now;
  final RetryBackoff retryBackoff;

  Result<OutboxOperation> transition(
    OutboxOperation operation,
    OutboxState next, {
    Failure? failure,
  }) {
    if (!isOutboxTransitionAllowed(operation.state, next)) {
      return FailureResult(
        StateFailure(
          message:
              'Invalid offline operation transition: '
              '${operation.state.wireValue} -> ${next.wireValue}.',
        ),
      );
    }

    final transitionedAt = now().toUtc();
    final failureCode = failure?.runtimeType.toString();
    if (next == OutboxState.retryableFailure) {
      final attemptCount = operation.attemptCount + 1;
      return Success(
        operation.copyWith(
          state: next,
          updatedAt: transitionedAt,
          attemptCount: attemptCount,
          nextAttemptAt: transitionedAt.add(retryBackoff(attemptCount)),
          lastFailureCode: failureCode,
          requiresStatusProbe: failure is NetworkFailure,
          clearSyncingStartedAt: true,
        ),
      );
    }

    return Success(
      operation.copyWith(
        state: next,
        updatedAt: transitionedAt,
        clearNextAttemptAt: next == OutboxState.syncing,
        lastFailureCode: failureCode,
        requiresStatusProbe: next == OutboxState.syncing
            ? operation.requiresStatusProbe
            : false,
        syncingStartedAt: next == OutboxState.syncing ? transitionedAt : null,
        clearSyncingStartedAt: next != OutboxState.syncing,
      ),
    );
  }
}

Duration _defaultBackoff(int attemptCount) {
  final exponent = attemptCount.clamp(1, 6) - 1;
  return Duration(seconds: 30 * (1 << exponent));
}
