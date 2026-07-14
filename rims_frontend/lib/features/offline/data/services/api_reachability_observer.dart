import 'dart:async';

import '../../../../core/network/api_client.dart';
import '../../../../core/result/failure.dart';
import '../../domain/services/network_status_service.dart';

final class ApiReachabilityObserver {
  const ApiReachabilityObserver(this.networkStatusService);

  final NetworkStatusService networkStatusService;

  void call(ApiRequestOutcome outcome) {
    if (outcome.succeeded) {
      networkStatusService.markOnlineFromRequest();
      return;
    }
    if (outcome.failure is NetworkFailure ||
        outcome.failure is TransportUnknownFailure) {
      unawaited(networkStatusService.verify());
    }
  }
}
