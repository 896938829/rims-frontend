import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/features/offline/data/services/api_reachability_observer.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';

void main() {
  test('successful requests mark the API reachable', () {
    final status = _FakeNetworkStatusService();
    final observer = ApiReachabilityObserver(status);

    observer(const ApiRequestOutcome(path: '/inventory', succeeded: true));

    expect(status.markOnlineCallCount, 1);
    expect(status.verifyCallCount, 0);
  });

  for (final failure in <Failure>[
    const NetworkFailure(),
    const TransportUnknownFailure(),
  ]) {
    test(
      '${failure.runtimeType} triggers an API health verification',
      () async {
        final status = _FakeNetworkStatusService();
        final observer = ApiReachabilityObserver(status);

        observer(
          ApiRequestOutcome(
            path: '/inventory',
            succeeded: false,
            failure: failure,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(status.verifyCallCount, 1);
        expect(status.markOnlineCallCount, 0);
      },
    );
  }

  test('business failures do not change API reachability', () async {
    final status = _FakeNetworkStatusService();
    final observer = ApiReachabilityObserver(status);

    observer(
      const ApiRequestOutcome(
        path: '/inventory',
        succeeded: false,
        failure: AuthorizationFailure(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(status.verifyCallCount, 0);
    expect(status.markOnlineCallCount, 0);
  });
}

final class _FakeNetworkStatusService implements NetworkStatusService {
  int markOnlineCallCount = 0;
  int verifyCallCount = 0;

  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  NetworkReachability get current => NetworkReachability.online;

  @override
  Future<void> dispose() async {}

  @override
  void markOnlineFromRequest() {
    markOnlineCallCount += 1;
  }

  @override
  Future<NetworkReachability> verify() async {
    verifyCallCount += 1;
    return current;
  }
}
