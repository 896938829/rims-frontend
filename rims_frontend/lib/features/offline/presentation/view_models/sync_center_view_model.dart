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

  List<OutboxOperation> get operations => _operations;
  Set<String> get reviewedOperationIds =>
      Set.unmodifiable(_reviewedOperationIds);
  Set<String> get selectedOperationIds =>
      Set.unmodifiable(_selectedOperationIds);
  bool get isBusy => _isBusy;
  Failure? get failure => _failure;

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

  Future<void> load() async {
    if (_isDisposed) return;
    final context = contextReader();
    _updateFingerprint(context);
    if (context == null) {
      _operations = const [];
      _failure = const AuthenticationFailure();
      _notifyListeners();
      return;
    }
    final result = await repository.list(context.accountId);
    result.when(
      success: (operations) {
        _operations = operations;
        _failure = null;
      },
      failure: (failure) => _failure = failure,
    );
    if (_isDisposed) return;
    final waitingIds = waiting
        .map((operation) => operation.operationId)
        .toSet();
    _reviewedOperationIds.retainAll(waitingIds);
    _selectedOperationIds.retainAll(waitingIds);
    _notifyListeners();
  }

  Future<void> refreshContext() => load();

  Future<bool> review(String operationId) async {
    if (_isDisposed) return false;
    final context = contextReader();
    _updateFingerprint(context);
    final operation = _find(operationId);
    if (context == null ||
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
    final context = contextReader();
    if (context == null) return;
    await _mutate(
      repository.cancel(accountId: context.accountId, operationId: operationId),
    );
  }

  Future<void> discard(String operationId) async {
    final context = contextReader();
    if (context == null) return;
    await _mutate(
      repository.discard(
        accountId: context.accountId,
        operationId: operationId,
      ),
    );
    _reviewedOperationIds.remove(operationId);
    _selectedOperationIds.remove(operationId);
  }

  Future<void> resolveConflict(
    String conflictedOperationId,
    OutboxOperation replacement, {
    Set<String> dependencies = const {},
  }) async {
    final context = contextReader();
    if (context == null) return;
    await _mutate(
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
    final context = contextReader();
    _updateFingerprint(context);
    if (context == null || operationIds.isEmpty) return;
    _isBusy = true;
    _failure = null;
    _notifyListeners();
    for (final operationId in operationIds) {
      final prepared = await repository.retryNow(
        accountId: context.accountId,
        operationId: operationId,
      );
      if (prepared case FailureResult<OutboxOperation>(:final failure)) {
        _failure = failure;
        _isBusy = false;
        _notifyListeners();
        return;
      }
    }
    final report = await executor.execute(
      OutboxReview(
        operationIds: Set.unmodifiable(operationIds),
        accountId: context.accountId,
        warehouseId: context.warehouseId,
        permissionStamp: context.permissionStamp,
      ),
    );
    _failure = report.failure;
    _isBusy = false;
    await load();
  }

  Future<void> _mutate(Future<Result<OutboxOperation>> future) async {
    if (_isDisposed) return;
    _isBusy = true;
    _notifyListeners();
    final result = await future;
    result.when(
      success: (_) => _failure = null,
      failure: (failure) => _failure = failure,
    );
    _isBusy = false;
    await load();
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
    final next = context == null
        ? null
        : '${context.accountId}:${context.warehouseId}:${context.permissionStamp}';
    if (_contextFingerprint != null && _contextFingerprint != next) {
      _reviewedOperationIds.clear();
      _selectedOperationIds.clear();
    }
    _contextFingerprint = next;
  }
}
