import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../domain/entities/network_reachability.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/network_status_service.dart';
import '../../domain/services/outbox_executor.dart';
import '../../domain/services/outbox_status_classifier.dart';

typedef OfflineStatusTimerFactory =
    Timer Function(Duration delay, void Function() callback);

final class OfflineStatusViewModel extends ChangeNotifier {
  OfflineStatusViewModel({
    required this.networkStatusService,
    required this.outboxRepository,
    required this.contextReader,
    DateTime Function()? now,
    OfflineStatusTimerFactory? scheduleTimer,
  }) : now = now ?? DateTime.now,
       scheduleTimer = scheduleTimer ?? Timer.new,
       _reachability = networkStatusService.current {
    _networkSubscription = networkStatusService.changes.listen(
      _handleReachability,
    );
    _synchronizeScope(contextReader(), notify: false);
  }

  final NetworkStatusService networkStatusService;
  final OutboxRepository? outboxRepository;
  final OutboxExecutionContext? Function() contextReader;
  final DateTime Function() now;
  final OfflineStatusTimerFactory scheduleTimer;
  static const OutboxStatusClassifier _statusClassifier =
      OutboxStatusClassifier();
  late final StreamSubscription<NetworkReachability> _networkSubscription;
  Timer? _freshnessTimer;

  NetworkReachability _reachability;
  DateTime? _fetchedAt;
  DateTime? _expiresAt;
  bool _hasCachedData = false;
  String? _scopeAccountId;
  int? _scopeWarehouseId;
  int _queuedCount = 0;
  int _attentionCount = 0;
  bool _isDisposed = false;
  int _loadGeneration = 0;

  NetworkReachability get reachability => _reachability;
  int get queuedCount => _queuedCount;
  int get attentionCount => _attentionCount;

  String get networkLabel => switch (_reachability) {
    NetworkReachability.checking => '正在检查服务',
    NetworkReachability.offline => '离线，无网络连接',
    NetworkReachability.unreachable => '网络可用，服务不可达',
    NetworkReachability.online => '在线，服务可用',
  };

  bool get isStale {
    final expiresAt = _expiresAt;
    return expiresAt != null && !now().toUtc().isBefore(expiresAt.toUtc());
  }

  String get dataAgeLabel {
    final fetchedAt = _fetchedAt;
    if (fetchedAt == null) return '数据时间未知';
    final age = now().toUtc().difference(fetchedAt.toUtc());
    final normalizedAge = age.isNegative ? Duration.zero : age;
    final ageText = switch (normalizedAge) {
      Duration(inMinutes: < 1) => '刚刚更新',
      Duration(inHours: < 1) => '${normalizedAge.inMinutes} 分钟前',
      Duration(inDays: < 1) => '${normalizedAge.inHours} 小时前',
      _ => '${normalizedAge.inDays} 天前',
    };
    if (isStale) return '陈旧缓存 · $ageText';
    return _hasCachedData ? '缓存数据 · $ageText' : '数据$ageText';
  }

  Future<void> load() => refreshCounts();

  Future<void> refreshCounts() async {
    final repository = outboxRepository;
    final context = contextReader();
    _synchronizeScope(context);
    final generation = ++_loadGeneration;
    if (repository == null || context == null) {
      _setCounts(0, 0);
      return;
    }
    final result = await repository.list(context.accountId);
    if (_isDisposed || generation != _loadGeneration) return;
    switch (result) {
      case Success<List<OutboxOperation>>(:final data):
        final visible = _statusClassifier.visibleOperations(
          operations: data,
          context: context,
        );
        final deniedIds = _statusClassifier.deniedOperationIds(
          operations: visible,
          context: context,
        );
        final component = await repository.loadConnectedComponent(
          accountId: context.accountId,
          operationIds: deniedIds,
        );
        if (_isDisposed || generation != _loadGeneration) return;
        final blockedIds = switch (component) {
          Success<List<OutboxOperation>>(:final data) =>
            data
                .map((operation) => operation.operationId)
                .where(
                  visible
                      .map((operation) => operation.operationId)
                      .toSet()
                      .contains,
                )
                .toSet(),
          FailureResult<List<OutboxOperation>>() => deniedIds,
        };
        final buckets = _statusClassifier.classify(
          operations: visible,
          permissionBlockedOperationIds: blockedIds,
        );
        _setCounts(buckets.waiting.length, buckets.attention.length);
      case FailureResult<List<OutboxOperation>>():
        break;
    }
  }

  void updateDataFreshness({
    required String accountId,
    required int warehouseId,
    DateTime? fetchedAt,
    DateTime? expiresAt,
    bool hasCachedData = false,
  }) {
    final context = contextReader();
    _synchronizeScope(context);
    if (context == null ||
        context.accountId != accountId ||
        context.warehouseId != warehouseId) {
      return;
    }
    if (_fetchedAt == fetchedAt &&
        _expiresAt == expiresAt &&
        _hasCachedData == hasCachedData) {
      return;
    }
    _fetchedAt = fetchedAt;
    _expiresAt = expiresAt;
    _hasCachedData = hasCachedData;
    _scheduleFreshnessUpdate();
    notifyListeners();
  }

  void refreshContext() {
    _synchronizeScope(contextReader());
  }

  void _synchronizeScope(
    OutboxExecutionContext? context, {
    bool notify = true,
  }) {
    final accountId = context?.accountId;
    final warehouseId = context?.warehouseId;
    if (_scopeAccountId == accountId && _scopeWarehouseId == warehouseId) {
      return;
    }
    _scopeAccountId = accountId;
    _scopeWarehouseId = warehouseId;
    _loadGeneration += 1;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _fetchedAt = null;
    _expiresAt = null;
    _hasCachedData = false;
    _queuedCount = 0;
    _attentionCount = 0;
    if (notify && !_isDisposed) notifyListeners();
  }

  void _scheduleFreshnessUpdate() {
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    final fetchedAt = _fetchedAt?.toUtc();
    if (fetchedAt == null || _isDisposed) return;
    final current = now().toUtc();
    final age = current.difference(fetchedAt);
    final normalizedAge = age.isNegative ? Duration.zero : age;
    final nextAgeBoundary = switch (normalizedAge) {
      Duration(inMinutes: < 1) => fetchedAt.add(const Duration(minutes: 1)),
      Duration(inHours: < 1) => fetchedAt.add(
        Duration(minutes: normalizedAge.inMinutes + 1),
      ),
      Duration(inDays: < 1) => fetchedAt.add(
        Duration(hours: normalizedAge.inHours + 1),
      ),
      _ => fetchedAt.add(Duration(days: normalizedAge.inDays + 1)),
    };
    var deadline = nextAgeBoundary;
    final expiresAt = _expiresAt?.toUtc();
    if (expiresAt != null &&
        current.isBefore(expiresAt) &&
        expiresAt.isBefore(deadline)) {
      deadline = expiresAt;
    }
    final delay = deadline.difference(current);
    _freshnessTimer = scheduleTimer(
      delay.isNegative ? Duration.zero : delay,
      _handleFreshnessTimer,
    );
  }

  void _handleFreshnessTimer() {
    _freshnessTimer = null;
    if (_isDisposed) return;
    notifyListeners();
    _scheduleFreshnessUpdate();
  }

  void _handleReachability(NetworkReachability reachability) {
    if (_reachability == reachability || _isDisposed) return;
    _reachability = reachability;
    notifyListeners();
  }

  void _setCounts(int queued, int attention) {
    if (_queuedCount == queued && _attentionCount == attention) return;
    _queuedCount = queued;
    _attentionCount = attention;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _loadGeneration += 1;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    unawaited(_networkSubscription.cancel());
    super.dispose();
  }
}
