import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../domain/entities/network_reachability.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/repositories/outbox_repository.dart';
import '../../domain/services/network_status_service.dart';

final class OfflineStatusViewModel extends ChangeNotifier {
  OfflineStatusViewModel({
    required this.networkStatusService,
    required this.outboxRepository,
    required this.accountIdReader,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       _reachability = networkStatusService.current {
    _networkSubscription = networkStatusService.changes.listen(
      _handleReachability,
    );
  }

  final NetworkStatusService networkStatusService;
  final OutboxRepository? outboxRepository;
  final String? Function() accountIdReader;
  final DateTime Function() now;
  late final StreamSubscription<NetworkReachability> _networkSubscription;

  NetworkReachability _reachability;
  DateTime? _fetchedAt;
  DateTime? _expiresAt;
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
    return expiresAt != null && now().toUtc().isAfter(expiresAt.toUtc());
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
    return isStale ? '陈旧缓存 · $ageText' : '数据$ageText';
  }

  Future<void> load() => refreshCounts();

  Future<void> refreshCounts() async {
    final generation = ++_loadGeneration;
    final repository = outboxRepository;
    final accountId = accountIdReader()?.trim();
    if (repository == null || accountId == null || accountId.isEmpty) {
      _setCounts(0, 0);
      return;
    }
    final result = await repository.list(accountId);
    if (_isDisposed || generation != _loadGeneration) return;
    switch (result) {
      case Success<List<OutboxOperation>>(:final data):
        _setCounts(
          data.where(_isQueued).length,
          data.where(_needsAttention).length,
        );
      case FailureResult<List<OutboxOperation>>():
        break;
    }
  }

  void updateDataFreshness({DateTime? fetchedAt, DateTime? expiresAt}) {
    if (_fetchedAt == fetchedAt && _expiresAt == expiresAt) return;
    _fetchedAt = fetchedAt;
    _expiresAt = expiresAt;
    notifyListeners();
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

  bool _isQueued(OutboxOperation operation) {
    return operation.state == OutboxState.queued ||
        operation.state == OutboxState.retryableFailure ||
        operation.state == OutboxState.syncing;
  }

  bool _needsAttention(OutboxOperation operation) {
    return operation.state == OutboxState.conflict ||
        operation.state == OutboxState.permanentFailure;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _loadGeneration += 1;
    unawaited(_networkSubscription.cancel());
    super.dispose();
  }
}
