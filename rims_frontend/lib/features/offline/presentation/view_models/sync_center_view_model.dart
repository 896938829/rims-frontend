import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/outbox_executor.dart';
import '../../domain/services/outbox_status_classifier.dart';

final class SyncConfirmationSummary {
  const SyncConfirmationSummary({
    required this.warehouse,
    required this.documentType,
    required this.lineCount,
    required this.staleAssumptions,
  });

  final String warehouse;
  final String documentType;
  final int lineCount;
  final List<String> staleAssumptions;
}

final class SyncCenterViewModel extends ChangeNotifier {
  SyncCenterViewModel({
    required this.repository,
    required this.executor,
    required this.contextReader,
    DateTime Function()? now,
    this.staleSyncingThreshold = const Duration(minutes: 5),
  }) : now = now ?? DateTime.now;

  final OutboxRepository repository;
  final OutboxExecutorPort executor;
  final OutboxExecutionContext? Function() contextReader;
  final DateTime Function() now;
  final Duration staleSyncingThreshold;
  static const OutboxStatusClassifier _statusClassifier =
      OutboxStatusClassifier();
  final Set<String> _reviewedOperationIds = {};
  final Set<String> _selectedOperationIds = {};
  final Set<String> _permissionBlockedOperationIds = {};
  List<OutboxOperation> _operations = const [];
  String? _contextFingerprint;
  bool _isBusy = false;
  bool _isLoading = false;
  Failure? _loadFailure;
  Failure? _commandFailure;
  bool _isDisposed = false;
  int _contextGeneration = 0;

  List<OutboxOperation> get operations => _operations;
  Set<String> get reviewedOperationIds =>
      Set.unmodifiable(_reviewedOperationIds);
  Set<String> get selectedOperationIds =>
      Set.unmodifiable(_selectedOperationIds);
  Set<String> get permissionBlockedOperationIds =>
      Set.unmodifiable(_permissionBlockedOperationIds);
  bool isPermissionBlocked(String operationId) =>
      _permissionBlockedOperationIds.contains(operationId);
  bool get isBusy => _isBusy;
  bool get isLoading => _isLoading;
  Failure? get loadFailure => _loadFailure;
  Failure? get commandFailure => _commandFailure;
  Failure? get failure => _commandFailure ?? _loadFailure;
  int get contextGeneration => _contextGeneration;

  OutboxStatusBuckets get _buckets => _statusClassifier.classify(
    operations: _operations,
    permissionBlockedOperationIds: _permissionBlockedOperationIds,
  );

  List<OutboxOperation> get waiting => _buckets.waiting;

  List<OutboxOperation> get attention => _buckets.attention;

  List<OutboxOperation> get completed => _buckets.completed;

  Future<void> load() => _beginLoad();

  Future<void> refreshContext() => _beginLoad();

  Future<void> _beginLoad() {
    final context = contextReader();
    final generation = ++_contextGeneration;
    _updateFingerprint(context);
    _isLoading = true;
    _notifyListeners();
    return _load(generation, context);
  }

  Future<void> _load(int generation, OutboxExecutionContext? context) async {
    if (_isDisposed) return;
    if (context == null) {
      if (!_acceptResult(generation, context)) return;
      _operations = const [];
      _permissionBlockedOperationIds.clear();
      _loadFailure = const AuthenticationFailure();
      _isLoading = false;
      _notifyListeners();
      return;
    }
    final result = await repository.list(context.accountId);
    if (!_acceptResult(generation, context)) return;
    if (result case FailureResult<List<OutboxOperation>>(:final failure)) {
      _operations = const [];
      _permissionBlockedOperationIds.clear();
      _loadFailure = failure;
    } else {
      _operations = _statusClassifier.visibleOperations(
        operations: (result as Success<List<OutboxOperation>>).data,
        context: context,
      );
      final deniedIds = _statusClassifier.deniedOperationIds(
        operations: _operations,
        context: context,
      );
      if (deniedIds.isEmpty) {
        _permissionBlockedOperationIds.clear();
        _loadFailure = null;
      } else {
        final component = await repository.loadConnectedComponent(
          accountId: context.accountId,
          operationIds: deniedIds,
        );
        if (!_acceptResult(generation, context)) return;
        _permissionBlockedOperationIds.clear();
        if (component case FailureResult<List<OutboxOperation>>(
          :final failure,
        )) {
          _loadFailure = failure;
        } else {
          final permissionRelevantIds = _statusClassifier
              .permissionRelevantOperationIds(operations: _operations);
          final fullComponent =
              (component as Success<List<OutboxOperation>>).data;
          final blockedComponent = fullComponent
              .where(
                (operation) =>
                    permissionRelevantIds.contains(operation.operationId),
              )
              .toList(growable: false);
          _permissionBlockedOperationIds.addAll(
            blockedComponent.map((operation) => operation.operationId),
          );
          if (blockedComponent.any(
            (operation) =>
                _isNonTerminal(operation) &&
                (operation.confirmedAt != null ||
                    operation.reviewStamp != null),
          )) {
            final invalidated = await repository.invalidateReviewGraph(
              accountId: context.accountId,
              expectedUpdatedAtByOperation: {
                for (final operation in fullComponent)
                  operation.operationId: operation.updatedAt,
              },
            );
            if (!_acceptResult(generation, context)) return;
            if (invalidated case FailureResult<List<OutboxOperation>>(
              :final failure,
            )) {
              _loadFailure = failure;
            } else {
              final invalidatedById = {
                for (final operation
                    in (invalidated as Success<List<OutboxOperation>>).data)
                  operation.operationId: operation,
              };
              _operations = [
                for (final operation in _operations)
                  invalidatedById[operation.operationId] ?? operation,
              ];
              _loadFailure = null;
            }
          } else {
            _loadFailure = null;
          }
        }
      }
    }
    _isLoading = false;
    final waitingIds = waiting
        .map((operation) => operation.operationId)
        .toSet();
    _reviewedOperationIds
      ..clear()
      ..addAll(
        waiting
            .where((operation) => operation.reviewStamp == context.reviewStamp)
            .map((operation) => operation.operationId),
      );
    _selectedOperationIds.retainAll(waitingIds);
    _notifyListeners();
  }

  Future<bool> review(String operationId) async {
    if (!_beginCommand()) return false;
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    final operation = _find(operationId);
    if (snapshot == null ||
        context == null ||
        operation == null ||
        operation.accountId != context.accountId ||
        operation.warehouseId != context.warehouseId ||
        !context.allowedKinds.contains(operation.kind)) {
      _commandFailure = const AuthorizationFailure(
        message:
            'Review requires the current account, warehouse, and permission.',
      );
      _notifyListeners();
      _endCommand();
      return false;
    }
    try {
      final componentResult = await repository.loadConnectedComponent(
        accountId: context.accountId,
        operationIds: {operationId},
      );
      if (!_acceptResult(snapshot.generation, context)) return false;
      if (componentResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        _commandFailure = failure;
        return false;
      }
      var component = (componentResult as Success<List<OutboxOperation>>).data
          .where((item) => item.warehouseId == context.warehouseId)
          .toList(growable: false);
      if (component.any((item) => !context.allowedKinds.contains(item.kind))) {
        _commandFailure = const AuthorizationFailure(
          message: '完整依赖图包含当前无权执行的操作，请恢复权限后重新复核',
        );
        return false;
      }
      final recovered = await repository.recoverStaleSyncing(
        accountId: context.accountId,
        staleBefore: now().toUtc().subtract(staleSyncingThreshold),
        operationIds: component.map((item) => item.operationId).toSet(),
      );
      if (!_acceptResult(snapshot.generation, context)) return false;
      if (recovered case FailureResult<int>(:final failure)) {
        _commandFailure = failure;
        return false;
      }
      final reloadedResult = await repository.loadConnectedComponent(
        accountId: context.accountId,
        operationIds: {operationId},
      );
      if (!_acceptResult(snapshot.generation, context)) return false;
      if (reloadedResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        _commandFailure = failure;
        return false;
      }
      component = (reloadedResult as Success<List<OutboxOperation>>).data
          .where((item) => item.warehouseId == context.warehouseId)
          .toList(growable: false);
      if (component.any((item) => !context.allowedKinds.contains(item.kind))) {
        _commandFailure = const AuthorizationFailure(
          message: '完整依赖图包含当前无权执行的操作，请恢复权限后重新复核',
        );
        return false;
      }
      if (component.any((item) => item.state == OutboxState.syncing)) {
        _commandFailure = const StateFailure(message: '同步正在处理中，请稍后刷新后再复核');
        return false;
      }
      final confirmedById = <String, OutboxOperation>{};
      for (final item in component.where(_isReviewable)) {
        final result = await repository.confirm(
          accountId: context.accountId,
          operationId: item.operationId,
          reviewStamp: context.reviewStamp,
          expectedUpdatedAt: item.updatedAt,
        );
        if (!_acceptResult(snapshot.generation, context)) return false;
        if (result case FailureResult<OutboxOperation>(:final failure)) {
          _commandFailure = failure;
          return false;
        }
        confirmedById[item.operationId] =
            (result as Success<OutboxOperation>).data;
      }
      _reviewedOperationIds.addAll(confirmedById.keys);
      _operations = [
        for (final item in _operations) confirmedById[item.operationId] ?? item,
      ];
      return true;
    } finally {
      _endCommand();
    }
  }

  void setSelected(String operationId, bool selected) {
    final snapshot = _commandSnapshot();
    final operation = _find(operationId);
    if (snapshot == null ||
        operation == null ||
        !_isAllowed(snapshot.context, operation)) {
      return;
    }
    if (selected) {
      _selectedOperationIds.add(operationId);
    } else {
      _selectedOperationIds.remove(operationId);
    }
    _notifyListeners();
  }

  Future<void> reviewAndSync(String operationId) async {
    if (await review(operationId)) await _execute({operationId});
  }

  Future<void> retrySelected() =>
      _execute(_selectedOperationIds.intersection(_reviewedOperationIds));

  Future<void> retryAllReviewed() => _execute(_reviewedOperationIds);

  Future<void> cancel(String operationId) async {
    await _mutateVisible(
      operationId,
      (context) => repository.cancel(
        accountId: context.accountId,
        operationId: operationId,
      ),
    );
  }

  Future<void> discard(String operationId) async {
    if (!_beginCommand()) return;
    final snapshot = _commandSnapshot();
    final operation = _find(operationId);
    if (snapshot == null ||
        operation == null ||
        !_isAllowed(snapshot.context, operation)) {
      _rejectScope();
      _endCommand();
      return;
    }
    try {
      final result = await repository.discardComponent(
        accountId: snapshot.context.accountId,
        operationId: operationId,
      );
      if (!_acceptResult(snapshot.generation, snapshot.context)) return;
      if (result case FailureResult<List<OutboxOperation>>(:final failure)) {
        _commandFailure = failure;
      } else {
        final discardedIds = (result as Success<List<OutboxOperation>>).data
            .map((item) => item.operationId)
            .toSet();
        _reviewedOperationIds.removeAll(discardedIds);
        _selectedOperationIds.removeAll(discardedIds);
      }
      await _load(snapshot.generation, snapshot.context);
    } finally {
      _endCommand();
    }
  }

  Future<void> resolveConflict(
    String conflictedOperationId,
    OutboxOperation replacement, {
    Set<String> dependencies = const {},
  }) async {
    final snapshot = _commandSnapshot();
    final original = _find(conflictedOperationId);
    if (snapshot == null ||
        original == null ||
        !_isAllowed(snapshot.context, original) ||
        !_isAllowed(snapshot.context, replacement)) {
      _rejectScope();
      return;
    }
    await _mutateVisible(
      conflictedOperationId,
      (context) => repository.resolveConflict(
        accountId: context.accountId,
        conflictedOperationId: conflictedOperationId,
        replacement: replacement,
        dependencies: dependencies,
      ),
    );
  }

  SyncConfirmationSummary confirmationSummary(String operationId) {
    final operation = _find(operationId);
    if (operation == null) {
      return const SyncConfirmationSummary(
        warehouse: '',
        documentType: '',
        lineCount: 0,
        staleAssumptions: [],
      );
    }
    final payload = operation.payload;
    final rawLines = payload['lines'];
    final rawAssumptions = payload['staleAssumptions'];
    return SyncConfirmationSummary(
      warehouse:
          payload['warehouseName']?.toString() ?? '仓库 ${operation.warehouseId}',
      documentType:
          payload['documentType']?.toString() ?? operation.kind.wireValue,
      lineCount: rawLines is List ? rawLines.length : 0,
      staleAssumptions: rawAssumptions is List
          ? List.unmodifiable(rawAssumptions.map((item) => item.toString()))
          : const [],
    );
  }

  Future<void> _execute(Set<String> operationIds) async {
    if (!_beginCommand()) return;
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    if (snapshot == null || context == null) {
      _endCommand();
      return;
    }
    final requestedIds = operationIds
        .intersection(_reviewedOperationIds)
        .toSet();
    if (requestedIds.isEmpty) {
      _endCommand();
      return;
    }
    try {
      final componentResult = await repository.loadConnectedComponent(
        accountId: context.accountId,
        operationIds: requestedIds,
      );
      if (!_acceptResult(snapshot.generation, context)) return;
      if (componentResult case FailureResult<List<OutboxOperation>>(
        :final failure,
      )) {
        _commandFailure = failure;
        return;
      }
      final component =
          (componentResult as Success<List<OutboxOperation>>).data;
      if (component.any((operation) => !_isAllowed(context, operation))) {
        _commandFailure = const AuthorizationFailure(
          message: '完整依赖图权限不足，未执行任何同步操作',
        );
        return;
      }
      final eligibleOperationIds = component
          .where(_isReviewable)
          .where(
            (operation) =>
                _reviewedOperationIds.contains(operation.operationId) &&
                operation.reviewStamp == context.reviewStamp,
          )
          .map((operation) => operation.operationId)
          .toSet();
      if (eligibleOperationIds.length !=
          component.where(_isReviewable).length) {
        _commandFailure = const AuthorizationFailure(
          message: '完整依赖图必须在当前权限上下文中重新复核',
        );
        return;
      }
      for (final operationId in eligibleOperationIds) {
        final prepared = await repository.retryNow(
          accountId: context.accountId,
          operationId: operationId,
        );
        if (!_acceptResult(snapshot.generation, context)) return;
        if (prepared case FailureResult<OutboxOperation>(:final failure)) {
          _commandFailure = failure;
          return;
        }
      }
      final report = await executor.execute(
        OutboxReview(
          operationIds: Set.unmodifiable(eligibleOperationIds),
          accountId: context.accountId,
          warehouseId: context.warehouseId,
          permissionStamp: context.permissionStamp,
        ),
      );
      if (!_acceptResult(snapshot.generation, context)) return;
      if (report.failure != null) _commandFailure = report.failure;
      await _load(snapshot.generation, context);
    } finally {
      _endCommand();
    }
  }

  Future<bool> _mutateVisible(
    String operationId,
    Future<Result<OutboxOperation>> Function(OutboxExecutionContext context)
    mutation,
  ) async {
    if (!_beginCommand()) return false;
    final snapshot = _commandSnapshot();
    final operation = _find(operationId);
    if (snapshot == null ||
        operation == null ||
        !_isAllowed(snapshot.context, operation)) {
      _rejectScope();
      _endCommand();
      return false;
    }
    try {
      final result = await mutation(snapshot.context);
      if (!_acceptResult(snapshot.generation, snapshot.context)) return false;
      final applied = result.when(
        success: (_) => true,
        failure: (failure) {
          _commandFailure = failure;
          return false;
        },
      );
      await _load(snapshot.generation, snapshot.context);
      return applied;
    } finally {
      _endCommand();
    }
  }

  void dismissCommandFailure() {
    if (_isDisposed || _commandFailure == null) return;
    _commandFailure = null;
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    super.dispose();
  }

  OutboxOperation? _find(String operationId) {
    for (final operation in _operations) {
      if (operation.operationId == operationId) return operation;
    }
    return null;
  }

  void _updateFingerprint(OutboxExecutionContext? context) {
    final next = _fingerprint(context);
    if (_contextFingerprint != null && _contextFingerprint != next) {
      _reviewedOperationIds.clear();
      _selectedOperationIds.clear();
      _operations = const [];
      _permissionBlockedOperationIds.clear();
      _loadFailure = null;
    }
    _contextFingerprint = next;
  }

  _ContextSnapshot? _commandSnapshot() {
    if (_isDisposed) return null;
    final context = contextReader();
    final nextFingerprint = _fingerprint(context);
    if (nextFingerprint != _contextFingerprint) {
      _contextGeneration += 1;
      _updateFingerprint(context);
    }
    if (context == null) return null;
    return _ContextSnapshot(generation: _contextGeneration, context: context);
  }

  bool _acceptResult(int generation, OutboxExecutionContext? context) {
    if (_isDisposed || generation != _contextGeneration) return false;
    final current = contextReader();
    if (_fingerprint(current) == _fingerprint(context)) return true;
    _contextGeneration += 1;
    _updateFingerprint(current);
    _notifyListeners();
    return false;
  }

  String? _fingerprint(OutboxExecutionContext? context) => context == null
      ? null
      : '${context.accountId}:${context.warehouseId}:${context.permissionStamp}';

  bool _beginCommand() {
    if (_isDisposed) return false;
    if (_isBusy) {
      _commandFailure = const StateFailure(
        message: 'Another synchronization command is already running.',
      );
      _notifyListeners();
      return false;
    }
    _isBusy = true;
    _commandFailure = null;
    _notifyListeners();
    return true;
  }

  void _endCommand() {
    _isBusy = false;
    _notifyListeners();
  }

  bool _isAllowed(OutboxExecutionContext context, OutboxOperation operation) =>
      operation.accountId == context.accountId &&
      operation.warehouseId == context.warehouseId &&
      context.allowedKinds.contains(operation.kind);

  bool _isReviewable(OutboxOperation operation) =>
      operation.state == OutboxState.queued ||
      operation.state == OutboxState.retryableFailure;

  bool _isNonTerminal(OutboxOperation operation) =>
      operation.state == OutboxState.queued ||
      operation.state == OutboxState.syncing ||
      operation.state == OutboxState.retryableFailure;

  void _rejectScope() {
    _commandFailure = const AuthorizationFailure(
      message:
          'The current account, warehouse, or permission cannot change this operation.',
    );
    _notifyListeners();
  }
}

final class _ContextSnapshot {
  const _ContextSnapshot({required this.generation, required this.context});

  final int generation;
  final OutboxExecutionContext context;
}
