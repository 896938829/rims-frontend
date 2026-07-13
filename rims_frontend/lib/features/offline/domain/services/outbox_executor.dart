import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../data/datasources/operation_status_remote_datasource.dart';
import '../entities/network_reachability.dart';
import '../entities/outbox_operation.dart';
import '../repositories/outbox_repository.dart';
import 'network_status_service.dart';

typedef OutboxDelay = Future<void> Function(Duration duration);
typedef ProbeBackoff = Duration Function(int attempt);

abstract interface class OutboxOperationHandler {
  OutboxOperationKind get kind;

  String get statusScope;

  Future<Result<Object?>> execute(OutboxOperation operation);
}

final class OutboxExecutionContext {
  const OutboxExecutionContext({
    required this.accountId,
    required this.warehouseId,
    required this.permissionStamp,
    required this.allowedKinds,
  });

  final String accountId;
  final int warehouseId;
  final String permissionStamp;
  final Set<OutboxOperationKind> allowedKinds;
}

final class OutboxReview {
  const OutboxReview({
    required this.operationIds,
    required this.accountId,
    required this.warehouseId,
    required this.permissionStamp,
  });

  final Set<String> operationIds;
  final String accountId;
  final int warehouseId;
  final String permissionStamp;
}

final class OutboxExecutionReport {
  const OutboxExecutionReport({
    this.succeededOperationIds = const [],
    this.paused = false,
    this.reviewInvalidated = false,
    this.skippedOperationReasons = const {},
    this.failure,
  });

  final List<String> succeededOperationIds;
  final bool paused;
  final bool reviewInvalidated;
  final Map<String, String> skippedOperationReasons;
  final Failure? failure;
}

abstract interface class OutboxExecutorPort {
  Future<OutboxExecutionReport> execute(OutboxReview review);
}

final class OutboxExecutor implements OutboxExecutorPort {
  OutboxExecutor({
    required this.repository,
    required this.networkStatusService,
    required this.statusDataSource,
    required Iterable<OutboxOperationHandler> handlers,
    required this.contextReader,
    OutboxDelay? delay,
    ProbeBackoff? probeBackoff,
    this.maxStatusProbes = 3,
  }) : handlers = Map.unmodifiable({
         for (final handler in handlers) handler.kind: handler,
       }),
       delay = delay ?? Future<void>.delayed,
       probeBackoff = probeBackoff ?? _defaultProbeBackoff {
    if (maxStatusProbes < 1) {
      throw ArgumentError.value(maxStatusProbes, 'maxStatusProbes');
    }
  }

  final OutboxRepository repository;
  final NetworkStatusService networkStatusService;
  final OperationStatusRemoteDataSource statusDataSource;
  final Map<OutboxOperationKind, OutboxOperationHandler> handlers;
  final OutboxExecutionContext? Function() contextReader;
  final OutboxDelay delay;
  final ProbeBackoff probeBackoff;
  final int maxStatusProbes;
  bool _isExecuting = false;

  @override
  Future<OutboxExecutionReport> execute(OutboxReview review) async {
    if (_isExecuting) {
      return const OutboxExecutionReport(
        failure: StateFailure(message: 'Synchronization is already running.'),
      );
    }

    final contextFailure = _validateContext(review);
    if (contextFailure != null) {
      return OutboxExecutionReport(
        paused: true,
        reviewInvalidated: true,
        skippedOperationReasons: _skipAll(
          review.operationIds,
          'review_invalidated',
        ),
        failure: contextFailure,
      );
    }
    if (review.operationIds.isEmpty) return const OutboxExecutionReport();

    _isExecuting = true;
    try {
      final succeeded = <String>[];
      final processed = <String>{};
      final skipped = <String, String>{};
      Failure? lastFailure;

      while (true) {
        final currentContextFailure = _validateContext(review);
        if (currentContextFailure != null) {
          _markRemaining(
            review.operationIds,
            processed,
            skipped,
            'review_invalidated',
          );
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            paused: true,
            reviewInvalidated: true,
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: currentContextFailure,
          );
        }

        final readyResult = await repository.ready(review.accountId);
        if (readyResult case FailureResult<List<OutboxOperation>>(
          :final failure,
        )) {
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: failure,
          );
        }
        final candidates = (readyResult as Success<List<OutboxOperation>>).data
            .where(
              (operation) =>
                  review.operationIds.contains(operation.operationId) &&
                  !processed.contains(operation.operationId),
            )
            .toList(growable: false);
        if (candidates.isEmpty) break;
        final operation = candidates.first;
        final operationFailure = _validateOperation(review, operation);
        if (operationFailure != null) {
          _markRemaining(
            review.operationIds,
            processed,
            skipped,
            'review_invalidated',
          );
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            paused: true,
            reviewInvalidated: true,
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: operationFailure,
          );
        }
        if (!handlers.containsKey(operation.kind)) {
          processed.add(operation.operationId);
          skipped[operation.operationId] = 'handler_unavailable';
          lastFailure = const StateFailure(
            message: 'No handler for offline operation.',
          );
          continue;
        }

        final reachability = await networkStatusService.verify();
        if (reachability != NetworkReachability.online) {
          _markRemaining(
            review.operationIds,
            processed,
            skipped,
            'connectivity_unverified',
          );
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            paused: true,
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: const NetworkFailure(),
          );
        }
        final postVerifyFailure = _validateOperation(review, operation);
        if (postVerifyFailure != null) {
          _markRemaining(
            review.operationIds,
            processed,
            skipped,
            'review_invalidated',
          );
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            paused: true,
            reviewInvalidated: true,
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: postVerifyFailure,
          );
        }

        final outcome = await _executeOne(operation);
        processed.add(operation.operationId);
        if (outcome.succeeded) succeeded.add(operation.operationId);
        if (outcome.pauseBatch) {
          _markRemaining(
            review.operationIds,
            processed,
            skipped,
            'authentication_required',
          );
          return OutboxExecutionReport(
            succeededOperationIds: List.unmodifiable(succeeded),
            paused: outcome.pauseBatch,
            skippedOperationReasons: Map.unmodifiable(skipped),
            failure: outcome.failure,
          );
        }
        lastFailure = outcome.failure ?? lastFailure;
      }

      _markRemaining(review.operationIds, processed, skipped, 'not_ready');

      return OutboxExecutionReport(
        succeededOperationIds: List.unmodifiable(succeeded),
        skippedOperationReasons: Map.unmodifiable(skipped),
        failure: lastFailure,
      );
    } finally {
      _isExecuting = false;
    }
  }

  Map<String, String> _skipAll(Set<String> operationIds, String reason) =>
      Map.unmodifiable({
        for (final operationId in operationIds) operationId: reason,
      });

  void _markRemaining(
    Set<String> operationIds,
    Set<String> processed,
    Map<String, String> skipped,
    String reason,
  ) {
    for (final operationId in operationIds) {
      if (!processed.contains(operationId)) {
        skipped.putIfAbsent(operationId, () => reason);
      }
    }
  }

  Failure? _validateContext(OutboxReview review) {
    final context = contextReader();
    if (context == null) return const AuthenticationFailure();
    if (context.accountId != review.accountId ||
        context.warehouseId != review.warehouseId ||
        context.permissionStamp != review.permissionStamp) {
      return const AuthorizationFailure(
        message: 'Account, warehouse, or permissions changed; review again.',
      );
    }
    return null;
  }

  Failure? _validateOperation(OutboxReview review, OutboxOperation operation) {
    final contextFailure = _validateContext(review);
    if (contextFailure != null) return contextFailure;
    final context = contextReader()!;
    if (operation.accountId != context.accountId ||
        operation.warehouseId != context.warehouseId ||
        !context.allowedKinds.contains(operation.kind)) {
      return const AuthorizationFailure(
        message: 'The current session cannot synchronize this operation.',
      );
    }
    return null;
  }

  Future<_OperationOutcome> _executeOne(OutboxOperation operation) async {
    final handler = handlers[operation.kind];
    if (handler == null) {
      return const _OperationOutcome(
        failure: StateFailure(message: 'No handler for offline operation.'),
      );
    }
    final hadUnknownResult =
        operation.state == OutboxState.retryableFailure &&
        operation.lastFailureCode == 'NetworkFailure';
    final syncing = await repository.transition(
      accountId: operation.accountId,
      operationId: operation.operationId,
      next: OutboxState.syncing,
    );
    if (syncing case FailureResult<OutboxOperation>(:final failure)) {
      return _OperationOutcome(failure: failure);
    }
    final syncingOperation = (syncing as Success<OutboxOperation>).data;

    if (hadUnknownResult) {
      final probeOutcome = await _probeUnknown(syncingOperation, handler);
      if (probeOutcome != null) return probeOutcome;
    }
    return _handleResult(
      syncingOperation,
      await handler.execute(syncingOperation),
    );
  }

  Future<_OperationOutcome?> _probeUnknown(
    OutboxOperation operation,
    OutboxOperationHandler handler,
  ) async {
    for (var probe = 1; probe <= maxStatusProbes; probe += 1) {
      final result = await statusDataSource.loadStatus(
        key: operation.idempotencyKey,
        scope: handler.statusScope,
      );
      if (result case FailureResult<OperationStatus>(:final failure)) {
        if (failure is NotFoundFailure) return null;
        return _finishFailure(operation, failure);
      }
      final status = (result as Success<OperationStatus>).data;
      if (status.state == OperationState.completed) {
        return _handleResult(operation, await handler.execute(operation));
      }
      if (probe < maxStatusProbes) {
        await delay(probeBackoff(probe));
      }
    }
    return _finishFailure(
      operation,
      const NetworkFailure(message: 'Operation is still processing remotely.'),
    );
  }

  Future<_OperationOutcome> _handleResult(
    OutboxOperation operation,
    Result<Object?> result,
  ) async {
    if (result case FailureResult<Object?>(:final failure)) {
      return _finishFailure(operation, failure);
    }
    final transitioned = await repository.transition(
      accountId: operation.accountId,
      operationId: operation.operationId,
      next: OutboxState.succeeded,
    );
    return transitioned.when(
      success: (_) => const _OperationOutcome(succeeded: true),
      failure: (failure) => _OperationOutcome(failure: failure),
    );
  }

  Future<_OperationOutcome> _finishFailure(
    OutboxOperation operation,
    Failure failure,
  ) async {
    final next = switch (failure) {
      AuthenticationFailure() => OutboxState.retryableFailure,
      AuthorizationFailure() => OutboxState.permanentFailure,
      ConflictFailure() => OutboxState.conflict,
      ValidationFailure() || NotFoundFailure() => OutboxState.permanentFailure,
      _ => OutboxState.retryableFailure,
    };
    final transitioned = await repository.transition(
      accountId: operation.accountId,
      operationId: operation.operationId,
      next: next,
      failure: failure,
    );
    if (transitioned case FailureResult<OutboxOperation>(:final failure)) {
      return _OperationOutcome(failure: failure);
    }
    return _OperationOutcome(
      pauseBatch: failure is AuthenticationFailure,
      failure: failure,
    );
  }
}

final class _OperationOutcome {
  const _OperationOutcome({
    this.succeeded = false,
    this.pauseBatch = false,
    this.failure,
  });

  final bool succeeded;
  final bool pauseBatch;
  final Failure? failure;
}

Duration _defaultProbeBackoff(int attempt) =>
    Duration(seconds: 1 << (attempt.clamp(1, 5) - 1));
