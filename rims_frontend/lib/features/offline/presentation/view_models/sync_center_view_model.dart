import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/outbox_executor.dart';

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
  });

  final OutboxRepository repository;
  final OutboxExecutorPort executor;
  final OutboxExecutionContext? Function() contextReader;
  final Set<String> _reviewedOperationIds = {};
  final Set<String> _selectedOperationIds = {};
  List<OutboxOperation> _operations = const [];
  String? _contextFingerprint;
  bool _isBusy = false;
  Failure? _failure;
  bool _isDisposed = false;
  int _contextGeneration = 0;

  List<OutboxOperation> get operations => _operations;
  Set<String> get reviewedOperationIds =>
      Set.unmodifiable(_reviewedOperationIds);
  Set<String> get selectedOperationIds =>
      Set.unmodifiable(_selectedOperationIds);
  bool get isBusy => _isBusy;
  Failure? get failure => _failure;
  int get contextGeneration => _contextGeneration;

  List<OutboxOperation> get waiting => _operations
      .where(
        (operation) =>
            operation.state == OutboxState.queued ||
            operation.state == OutboxState.retryableFailure ||
            operation.state == OutboxState.syncing,
      )
      .toList(growable: false);

  List<OutboxOperation> get attention => _operations
      .where(
        (operation) =>
            operation.state == OutboxState.conflict ||
            operation.state == OutboxState.permanentFailure,
      )
      .toList(growable: false);

  List<OutboxOperation> get completed => _operations
      .where(
        (operation) =>
            operation.state == OutboxState.succeeded ||
            operation.state == OutboxState.cancelled,
      )
      .toList(growable: false);

  Future<void> load() => _beginLoad();

  Future<void> refreshContext() => _beginLoad();

  Future<void> _beginLoad() {
    final context = contextReader();
    final generation = ++_contextGeneration;
    _updateFingerprint(context);
    _isBusy = false;
    return _load(generation, context);
  }

  Future<void> _load(int generation, OutboxExecutionContext? context) async {
    if (_isDisposed) return;
    if (context == null) {
      if (!_acceptResult(generation, context)) return;
      _operations = const [];
      _failure = const AuthenticationFailure();
      _notifyListeners();
      return;
    }
    final result = await repository.list(context.accountId);
    if (!_acceptResult(generation, context)) return;
    result.when(
      success: (operations) {
        _operations = operations;
        _failure = null;
      },
      failure: (failure) => _failure = failure,
    );
    final waitingIds = waiting
        .map((operation) => operation.operationId)
        .toSet();
    _reviewedOperationIds.retainAll(waitingIds);
    _selectedOperationIds.retainAll(waitingIds);
    _notifyListeners();
  }

  Future<bool> review(String operationId) async {
    if (_isDisposed) return false;
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    final operation = _find(operationId);
    if (snapshot == null ||
        context == null ||
        operation == null ||
        operation.accountId != context.accountId ||
        operation.warehouseId != context.warehouseId ||
        !context.allowedKinds.contains(operation.kind)) {
      _failure = const AuthorizationFailure(
        message:
            'Review requires the current account, warehouse, and permission.',
      );
      _notifyListeners();
      return false;
    }
    final result = await repository.confirm(
      accountId: context.accountId,
      operationId: operationId,
    );
    if (!_acceptResult(snapshot.generation, context)) return false;
    final confirmed = result.when(
      success: (_) {
        _reviewedOperationIds.add(operationId);
        _failure = null;
        return true;
      },
      failure: (failure) {
        _failure = failure;
        return false;
      },
    );
    _notifyListeners();
    return confirmed;
  }

  void setSelected(String operationId, bool selected) {
    if (_commandSnapshot() == null) return;
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
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    if (snapshot == null || context == null) return;
    await _mutate(
      snapshot,
      repository.cancel(accountId: context.accountId, operationId: operationId),
    );
  }

  Future<void> discard(String operationId) async {
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    if (snapshot == null || context == null) return;
    final applied = await _mutate(
      snapshot,
      repository.discard(
        accountId: context.accountId,
        operationId: operationId,
      ),
    );
    if (!applied) return;
    _reviewedOperationIds.remove(operationId);
    _selectedOperationIds.remove(operationId);
  }

  Future<void> resolveConflict(
    String conflictedOperationId,
    OutboxOperation replacement, {
    Set<String> dependencies = const {},
  }) async {
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    if (snapshot == null || context == null) return;
    await _mutate(
      snapshot,
      repository.resolveConflict(
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
    if (_isDisposed) return;
    final snapshot = _commandSnapshot();
    final context = snapshot?.context;
    if (snapshot == null || context == null) return;
    final eligibleOperationIds = operationIds.intersection(
      _reviewedOperationIds,
    );
    if (eligibleOperationIds.isEmpty) return;
    _isBusy = true;
    _failure = null;
    _notifyListeners();
    for (final operationId in eligibleOperationIds) {
      final prepared = await repository.retryNow(
        accountId: context.accountId,
        operationId: operationId,
      );
      if (!_acceptResult(snapshot.generation, context)) return;
      if (prepared case FailureResult<OutboxOperation>(:final failure)) {
        _failure = failure;
        _isBusy = false;
        _notifyListeners();
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
    _failure = report.failure;
    _isBusy = false;
    await _load(snapshot.generation, context);
  }

  Future<bool> _mutate(
    _ContextSnapshot snapshot,
    Future<Result<OutboxOperation>> future,
  ) async {
    if (_isDisposed) return false;
    _isBusy = true;
    _notifyListeners();
    final result = await future;
    if (!_acceptResult(snapshot.generation, snapshot.context)) return false;
    result.when(
      success: (_) => _failure = null,
      failure: (failure) => _failure = failure,
    );
    _isBusy = false;
    await _load(snapshot.generation, snapshot.context);
    return true;
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
      _failure = null;
      _isBusy = false;
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
      _isBusy = false;
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
    _isBusy = false;
    _failure = null;
    _notifyListeners();
    return false;
  }

  String? _fingerprint(OutboxExecutionContext? context) => context == null
      ? null
      : '${context.accountId}:${context.warehouseId}:${context.permissionStamp}';
}

final class _ContextSnapshot {
  const _ContextSnapshot({required this.generation, required this.context});

  final int generation;
  final OutboxExecutionContext context;
}
