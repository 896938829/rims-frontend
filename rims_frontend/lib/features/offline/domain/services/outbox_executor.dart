import 'dart:async';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../data/datasources/operation_status_remote_datasource.dart';
import '../entities/network_reachability.dart';
import '../entities/outbox_operation.dart';
import '../entities/outbox_graph.dart';
import '../entities/outbox_cleanup_intent.dart';
import '../repositories/outbox_repository.dart';
import 'network_status_service.dart';
import 'idempotency_key_validator.dart';
import 'offline_ownership_service.dart';
import 'offline_write_barrier.dart';

typedef OutboxDelay = Future<void> Function(Duration duration);
typedef ProbeBackoff = Duration Function(int attempt);
typedef OutboxSuccessObserver = Future<void> Function(String accountId);

abstract interface class OutboxOperationHandler {
  OutboxOperationKind get kind;

  String get statusScope;

  Future<Result<OutboxHandlerSuccess>> execute(
    OutboxOperation operation, {
    Map<String, OutboxOperationOutput> dependencyOutputs = const {},
    OutboxHandlerExecutionContext executionContext =
        const OutboxHandlerExecutionContext.unverified(),
  });
}

final class OutboxHandlerExecutionContext {
  const OutboxHandlerExecutionContext.unverified()
    : completedReplayProof = null;

  const OutboxHandlerExecutionContext._completed(this.completedReplayProof);

  final OutboxCompletedReplayProof? completedReplayProof;
}

final class OutboxCompletedReplayProof {
  const OutboxCompletedReplayProof._({
    required this.referenceOperationId,
    required this.referenceIdempotencyKey,
    required this.lifecycleOperationId,
    required this.lifecycleKind,
    required this.lifecycleIdempotencyKey,
    required this.accountId,
    required this.warehouseId,
    required this.statusScope,
  });

  final String referenceOperationId;
  final String referenceIdempotencyKey;
  final String lifecycleOperationId;
  final OutboxOperationKind lifecycleKind;
  final String lifecycleIdempotencyKey;
  final String accountId;
  final int warehouseId;
  final String statusScope;

  bool matchesReference({
    required OutboxOperation reference,
    required OutboxOperationKind expectedLifecycleKind,
    required String expectedStatusScope,
  }) {
    late final String expectedReferenceKey;
    try {
      expectedReferenceKey = IdempotencyKeyValidator.compose(
        lifecycleIdempotencyKey,
        'document-reference',
      );
    } on ArgumentError {
      return false;
    }
    return lifecycleOperationId.isNotEmpty &&
        reference.operationId != lifecycleOperationId &&
        reference.operationId == referenceOperationId &&
        reference.idempotencyKey == referenceIdempotencyKey &&
        reference.idempotencyKey == expectedReferenceKey &&
        reference.accountId == accountId &&
        reference.warehouseId == warehouseId &&
        lifecycleKind == expectedLifecycleKind &&
        statusScope == expectedStatusScope;
  }
}

final class OutboxHandlerSuccess {
  const OutboxHandlerSuccess({required this.output, this.cleanup});

  final OutboxOperationOutput output;
  final OutboxCleanupRequest? cleanup;
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

  String get reviewStamp =>
      '$accountId\u0000$warehouseId\u0000$permissionStamp';
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

final class OutboxExecutor
    implements
        OutboxExecutorPort,
        OfflineMutationParticipant,
        OfflineMutationDiagnostics {
  OutboxExecutor({
    required this.repository,
    required this.networkStatusService,
    required this.statusDataSource,
    required Iterable<OutboxOperationHandler> handlers,
    required this.contextReader,
    OutboxDelay? delay,
    ProbeBackoff? probeBackoff,
    this.maxStatusProbes = 3,
    DateTime Function()? now,
    this.minimumReplayWindow = const Duration(seconds: 15),
    this.staleSyncingThreshold = const Duration(minutes: 5),
    this.onSuccessPersisted,
    this.writeBarrier,
  }) : handlers = Map.unmodifiable({
         for (final handler in handlers) handler.kind: handler,
       }),
       delay = delay ?? Future<void>.delayed,
       probeBackoff = probeBackoff ?? _defaultProbeBackoff,
       now = now ?? DateTime.now {
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
  final DateTime Function() now;
  final Duration minimumReplayWindow;
  final Duration staleSyncingThreshold;
  final OutboxSuccessObserver? onSuccessPersisted;
  final OfflineWriteBarrier? writeBarrier;
  bool _isExecuting = false;
  Completer<void>? _activeExecution;
  String? _activeAccountId;
  final List<_ExecutorMutationBlock> _mutationBlocks = [];

  Future<void> waitForQuiescence() {
    return _activeExecution?.future ?? Future<void>.value();
  }

  @override
  OfflineMutationBlock blockMutations(OfflineMutationScope scope) {
    final block = _ExecutorMutationBlock(this, scope);
    _mutationBlocks.add(block);
    return block;
  }

  @override
  String describeMutationState(OfflineMutationScope scope) =>
      'blocks=${_mutationBlocks.length}, isExecuting=$_isExecuting, '
      'activeAccount=$_activeAccountId, '
      'scopeActive=${_activeAccountId != null && scope.contains(_activeAccountId!)}';

  @override
  Future<OutboxExecutionReport> execute(OutboxReview requestedReview) {
    if (_mutationBlocks.any(
      (block) => block.scope.contains(requestedReview.accountId),
    )) {
      return Future.value(
        const OutboxExecutionReport(
          failure: StateFailure(
            message: 'Synchronization is blocked by an ownership transition.',
          ),
        ),
      );
    }
    final barrier = writeBarrier;
    if (barrier == null) return _execute(requestedReview);
    return barrier
        .protect(
          accountId: requestedReview.accountId,
          operation: () => _execute(requestedReview),
        )
        .onError<OfflineWriteBlockedException>(
          (_, _) => const OutboxExecutionReport(
            failure: StateFailure(
              message: 'Synchronization is blocked by an ownership transition.',
            ),
          ),
        );
  }

  Future<OutboxExecutionReport> _execute(OutboxReview requestedReview) async {
    if (_isExecuting) {
      return const OutboxExecutionReport(
        failure: StateFailure(message: 'Synchronization is already running.'),
      );
    }

    var review = requestedReview;
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
    _activeAccountId = requestedReview.accountId;
    final activeExecution = Completer<void>();
    _activeExecution = activeExecution;
    try {
      final componentResult = await repository.loadConnectedComponent(
        accountId: review.accountId,
        operationIds: review.operationIds,
      );
      if (componentResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        return OutboxExecutionReport(failure: failure);
      }
      final component =
          (componentResult as Success<List<OutboxOperation>>).data;
      review = OutboxReview(
        operationIds: Set.unmodifiable({
          ...review.operationIds,
          ...component.map((operation) => operation.operationId),
        }),
        accountId: review.accountId,
        warehouseId: review.warehouseId,
        permissionStamp: review.permissionStamp,
      );
      final graphScopeFailure = _validateGraphScope(review, component);
      if (graphScopeFailure != null) {
        return OutboxExecutionReport(
          paused: true,
          reviewInvalidated: true,
          skippedOperationReasons: _skipAll(
            review.operationIds,
            'review_invalidated',
          ),
          failure: graphScopeFailure,
        );
      }
      final recovery = await repository.recoverStaleSyncing(
        accountId: review.accountId,
        staleBefore: now().toUtc().subtract(staleSyncingThreshold),
        operationIds: review.operationIds,
      );
      if (recovery case FailureResult<int>(:final failure)) {
        return OutboxExecutionReport(failure: failure);
      }
      final reloadedResult = await repository.loadConnectedComponent(
        accountId: review.accountId,
        operationIds: review.operationIds,
      );
      if (reloadedResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        return OutboxExecutionReport(failure: failure);
      }
      final reloaded = (reloadedResult as Success<List<OutboxOperation>>).data;
      review = OutboxReview(
        operationIds: Set.unmodifiable({
          ...review.operationIds,
          ...reloaded.map((operation) => operation.operationId),
        }),
        accountId: review.accountId,
        warehouseId: review.warehouseId,
        permissionStamp: review.permissionStamp,
      );
      final persistedReviewFailure = await _validatePersistedReview(
        review,
        const {},
      );
      if (persistedReviewFailure != null) {
        return OutboxExecutionReport(
          paused: true,
          reviewInvalidated: true,
          skippedOperationReasons: _skipAll(
            review.operationIds,
            'review_invalidated',
          ),
          failure: persistedReviewFailure,
        );
      }
      final initiallyReadyResult = await repository.ready(
        review.accountId,
        reviewStamp: _reviewStamp(review),
      );
      if (initiallyReadyResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        return OutboxExecutionReport(failure: failure);
      }
      final initiallyReadyIds = {
        for (final operation
            in (initiallyReadyResult as Success<List<OutboxOperation>>).data)
          operation.operationId,
      };
      final preflightStatusResults = <String, Result<OperationStatus>>{};
      final completedReplayProofs = <String, OutboxCompletedReplayProof>{};
      for (final operation in reloaded) {
        if (!review.operationIds.contains(operation.operationId) ||
            initiallyReadyIds.contains(operation.operationId) ||
            !_requiresCurrentReview(operation) ||
            !operation.requiresStatusProbe) {
          continue;
        }
        final handler = handlers[operation.kind];
        if (handler == null) continue;
        final reachability = await networkStatusService.verify();
        if (reachability != NetworkReachability.online) {
          return OutboxExecutionReport(
            paused: true,
            skippedOperationReasons: _skipAll(
              review.operationIds,
              'connectivity_unverified',
            ),
            failure: const NetworkFailure(),
          );
        }
        final operationFailure = _validateOperation(review, operation);
        if (operationFailure != null) {
          return OutboxExecutionReport(
            paused: true,
            reviewInvalidated: true,
            skippedOperationReasons: _skipAll(
              review.operationIds,
              'review_invalidated',
            ),
            failure: operationFailure,
          );
        }
        final statusResult = await statusDataSource.loadStatus(
          key: operation.idempotencyKey,
          scope: handler.statusScope,
        );
        if (statusResult case FailureResult<OperationStatus>(
          :final failure,
        ) when failure is! NotFoundFailure) {
          final syncing = await repository.transition(
            accountId: operation.accountId,
            operationId: operation.operationId,
            next: OutboxState.syncing,
          );
          if (syncing case FailureResult<OutboxOperation>(:final failure)) {
            return OutboxExecutionReport(failure: failure);
          }
          final outcome = await _finishFailure(
            (syncing as Success<OutboxOperation>).data,
            failure,
          );
          return OutboxExecutionReport(
            paused: outcome.pauseBatch,
            skippedOperationReasons: _skipAll(
              review.operationIds,
              'status_probe_failed',
            ),
            failure: outcome.failure,
          );
        }
        preflightStatusResults[operation.operationId] = statusResult;
        if (statusResult case Success<OperationStatus>(:final data)
            when data.state == OperationState.completed &&
                _hasSafeCompletedReplayLease(data)) {
          _bindCompletedReplayProof(
            lifecycleOperation: operation,
            lifecycleHandler: handler,
            component: reloaded,
            proofsByReferenceId: completedReplayProofs,
          );
        }
      }
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

        final readyResult = await repository.ready(
          review.accountId,
          reviewStamp: _reviewStamp(review),
        );
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
        if (candidates.isEmpty) {
          final reviewedFailure = await _validatePersistedReview(
            review,
            processed,
          );
          if (reviewedFailure != null) {
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
              failure: reviewedFailure,
            );
          }
          break;
        }
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
          skipped[operation.operationId] = 'unsupported_operation';
          const unsupported = UnsupportedOperationFailure(
            message: 'This offline operation is not supported by this app.',
          );
          final syncing = await repository.transition(
            accountId: operation.accountId,
            operationId: operation.operationId,
            next: OutboxState.syncing,
          );
          if (syncing case Success<OutboxOperation>()) {
            final terminal = await repository.transition(
              accountId: operation.accountId,
              operationId: operation.operationId,
              next: OutboxState.permanentFailure,
              failure: unsupported,
            );
            if (terminal case FailureResult<OutboxOperation>(:final failure)) {
              return OutboxExecutionReport(
                succeededOperationIds: List.unmodifiable(succeeded),
                skippedOperationReasons: Map.unmodifiable(skipped),
                failure: failure,
              );
            }
          } else if (syncing case FailureResult<OutboxOperation>(
            :final failure,
          )) {
            return OutboxExecutionReport(
              succeededOperationIds: List.unmodifiable(succeeded),
              skippedOperationReasons: Map.unmodifiable(skipped),
              failure: failure,
            );
          }
          lastFailure = unsupported;
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

        final completedReplayProof = completedReplayProofs.remove(
          operation.operationId,
        );
        final outcome = await _executeOne(
          operation,
          preflightStatusResult: preflightStatusResults.remove(
            operation.operationId,
          ),
          executionContext: completedReplayProof == null
              ? const OutboxHandlerExecutionContext.unverified()
              : OutboxHandlerExecutionContext._completed(completedReplayProof),
        );
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
      _activeAccountId = null;
      if (identical(_activeExecution, activeExecution)) {
        _activeExecution = null;
      }
      activeExecution.complete();
    }
  }

  Future<void> _waitForScope(OfflineMutationScope scope) {
    final accountId = _activeAccountId;
    if (accountId == null || !scope.contains(accountId)) {
      return Future<void>.value();
    }
    return _activeExecution?.future ?? Future<void>.value();
  }

  void _releaseMutationBlock(_ExecutorMutationBlock block) {
    _mutationBlocks.remove(block);
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

  Failure? _validateGraphScope(
    OutboxReview review,
    Iterable<OutboxOperation> operations,
  ) {
    for (final operation in operations) {
      final failure = _validateOperation(review, operation);
      if (failure != null) return failure;
    }
    return null;
  }

  Future<Failure?> _validatePersistedReview(
    OutboxReview review,
    Set<String> processed,
  ) async {
    final listed = await repository.list(review.accountId);
    if (listed case FailureResult<List<OutboxOperation>>(:final failure)) {
      return failure;
    }
    final byId = {
      for (final operation in (listed as Success<List<OutboxOperation>>).data)
        operation.operationId: operation,
    };
    for (final id in review.operationIds) {
      if (processed.contains(id)) continue;
      final operation = byId[id];
      if (operation == null) continue;
      final failure = _validateOperation(review, operation);
      if (failure != null) return failure;
      if (_requiresCurrentReview(operation) &&
          operation.reviewStamp != _reviewStamp(review)) {
        return const AuthorizationFailure(
          message: 'The operation must be reviewed in the current context.',
        );
      }
    }
    return null;
  }

  bool _requiresCurrentReview(OutboxOperation operation) =>
      operation.state == OutboxState.queued ||
      operation.state == OutboxState.syncing ||
      operation.state == OutboxState.retryableFailure;

  Future<_OperationOutcome> _executeOne(
    OutboxOperation operation, {
    Result<OperationStatus>? preflightStatusResult,
    OutboxHandlerExecutionContext executionContext =
        const OutboxHandlerExecutionContext.unverified(),
  }) async {
    final handler = handlers[operation.kind];
    if (handler == null) {
      return const _OperationOutcome(
        failure: StateFailure(message: 'No handler for offline operation.'),
      );
    }
    final hadUnknownResult = operation.requiresStatusProbe;
    final syncing = await repository.transition(
      accountId: operation.accountId,
      operationId: operation.operationId,
      next: OutboxState.syncing,
    );
    if (syncing case FailureResult<OutboxOperation>(:final failure)) {
      return _OperationOutcome(failure: failure);
    }
    final syncingOperation = (syncing as Success<OutboxOperation>).data;

    if (hadUnknownResult &&
        operation.kind != OutboxOperationKind.documentReference) {
      final probeOutcome = await _probeUnknown(
        syncingOperation,
        handler,
        preflightStatusResult: preflightStatusResult,
      );
      if (probeOutcome != null) return probeOutcome;
    }
    return _executeHandler(
      syncingOperation,
      handler,
      executionContext: executionContext,
    );
  }

  Future<_OperationOutcome?> _probeUnknown(
    OutboxOperation operation,
    OutboxOperationHandler handler, {
    Result<OperationStatus>? preflightStatusResult,
  }) async {
    for (var probe = 1; probe <= maxStatusProbes; probe += 1) {
      final result = probe == 1 && preflightStatusResult != null
          ? preflightStatusResult
          : await statusDataSource.loadStatus(
              key: operation.idempotencyKey,
              scope: handler.statusScope,
            );
      if (result case FailureResult<OperationStatus>(:final failure)) {
        if (failure is NotFoundFailure) return null;
        return _finishFailure(operation, failure);
      }
      final status = (result as Success<OperationStatus>).data;
      if (status.state == OperationState.completed) {
        if (!_hasSafeCompletedReplayLease(status)) {
          const failure = StateFailure(
            message: 'Completed operation replay lease is not safely valid.',
          );
          final transitioned = await repository.transition(
            accountId: operation.accountId,
            operationId: operation.operationId,
            next: OutboxState.permanentFailure,
            failure: failure,
          );
          return transitioned.when(
            success: (_) => const _OperationOutcome(failure: failure),
            failure: (transitionFailure) =>
                _OperationOutcome(failure: transitionFailure),
          );
        }
        return _executeHandler(operation, handler);
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

  String _reviewStamp(OutboxReview review) =>
      '${review.accountId}\u0000${review.warehouseId}\u0000${review.permissionStamp}';

  Future<_OperationOutcome> _executeHandler(
    OutboxOperation operation,
    OutboxOperationHandler handler, {
    OutboxHandlerExecutionContext executionContext =
        const OutboxHandlerExecutionContext.unverified(),
  }) async {
    final dependencyResult = await repository.loadDependencyOutputs(
      accountId: operation.accountId,
      operationId: operation.operationId,
    );
    if (dependencyResult case FailureResult<Map<String, OutboxOperationOutput>>(
      :final failure,
    )) {
      return _finishFailure(operation, failure);
    }
    return _handleResult(
      operation,
      await handler.execute(
        operation,
        dependencyOutputs:
            (dependencyResult as Success<Map<String, OutboxOperationOutput>>)
                .data,
        executionContext: executionContext,
      ),
    );
  }

  bool _hasSafeCompletedReplayLease(OperationStatus status) =>
      status.expiresAt.isAfter(now().toUtc().add(minimumReplayWindow));

  void _bindCompletedReplayProof({
    required OutboxOperation lifecycleOperation,
    required OutboxOperationHandler lifecycleHandler,
    required List<OutboxOperation> component,
    required Map<String, OutboxCompletedReplayProof> proofsByReferenceId,
  }) {
    late final String expectedReferenceKey;
    try {
      expectedReferenceKey = IdempotencyKeyValidator.compose(
        lifecycleOperation.idempotencyKey,
        'document-reference',
      );
    } on ArgumentError {
      return;
    }
    for (final reference in component) {
      if (reference.kind != OutboxOperationKind.documentReference ||
          reference.idempotencyKey != expectedReferenceKey ||
          reference.accountId != lifecycleOperation.accountId ||
          reference.warehouseId != lifecycleOperation.warehouseId) {
        continue;
      }
      proofsByReferenceId[reference.operationId] = OutboxCompletedReplayProof._(
        referenceOperationId: reference.operationId,
        referenceIdempotencyKey: reference.idempotencyKey,
        lifecycleOperationId: lifecycleOperation.operationId,
        lifecycleKind: lifecycleOperation.kind,
        lifecycleIdempotencyKey: lifecycleOperation.idempotencyKey,
        accountId: lifecycleOperation.accountId,
        warehouseId: lifecycleOperation.warehouseId,
        statusScope: lifecycleHandler.statusScope,
      );
    }
  }

  Future<_OperationOutcome> _handleResult(
    OutboxOperation operation,
    Result<OutboxHandlerSuccess> result,
  ) async {
    if (result case FailureResult<OutboxHandlerSuccess>(:final failure)) {
      return _finishFailure(operation, failure);
    }
    final success = (result as Success<OutboxHandlerSuccess>).data;
    final transitioned = await repository.completeSuccess(
      accountId: operation.accountId,
      operationId: operation.operationId,
      output: success.output,
      cleanup: success.cleanup,
    );
    if (transitioned case FailureResult<OutboxOperation>(:final failure)) {
      return _OperationOutcome(failure: failure);
    }
    await onSuccessPersisted?.call(operation.accountId);
    return const _OperationOutcome(succeeded: true);
  }

  Future<_OperationOutcome> _finishFailure(
    OutboxOperation operation,
    Failure failure,
  ) async {
    final next = switch (failure) {
      AuthenticationFailure() => OutboxState.retryableFailure,
      AuthorizationFailure() => OutboxState.permanentFailure,
      ConflictFailure() => OutboxState.conflict,
      ValidationFailure() ||
      NotFoundFailure() ||
      InventoryFailure() ||
      UnknownFailure() => OutboxState.permanentFailure,
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

final class _ExecutorMutationBlock implements OfflineMutationBlock {
  _ExecutorMutationBlock(this.executor, this.scope);

  final OutboxExecutor executor;
  final OfflineMutationScope scope;
  bool _released = false;

  @override
  final Object blockId = Object();

  @override
  Future<void> waitForQuiescence() => executor._waitForScope(scope);

  @override
  void release() {
    if (_released) return;
    _released = true;
    executor._releaseMutationBlock(this);
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
