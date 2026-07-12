import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/data/services/connectivity_network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';

void main() {
  test('no connectivity becomes offline without probing health', () async {
    var probes = 0;
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.none],
      connectivityChanges: const Stream.empty(),
      healthProbe: () async {
        probes += 1;
        return true;
      },
    );
    addTearDown(service.dispose);

    expect(await service.verify(), NetworkReachability.offline);
    expect(service.current, NetworkReachability.offline);
    expect(probes, 0);
  });

  test('connectivity remains checking until health is verified', () async {
    final probe = Completer<bool>();
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream.empty(),
      healthProbe: () => probe.future,
    );
    addTearDown(service.dispose);

    final result = service.verify();
    await Future<void>.delayed(Duration.zero);
    expect(service.current, NetworkReachability.checking);

    probe.complete(true);
    expect(await result, NetworkReachability.online);
    expect(service.current, NetworkReachability.online);
  });

  test('connected network with failed health probe is unreachable', () async {
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.mobile],
      connectivityChanges: const Stream.empty(),
      healthProbe: () async => false,
    );
    addTearDown(service.dispose);

    expect(await service.verify(), NetworkReachability.unreachable);
  });

  test('health timeout is unreachable', () async {
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream.empty(),
      healthProbe: () => Completer<bool>().future,
      probeTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(service.dispose);

    expect(await service.verify(), NetworkReachability.unreachable);
  });

  test('network loss invalidates an older successful probe', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final probe = Completer<bool>();
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.wifi],
      connectivityChanges: changes.stream,
      healthProbe: () => probe.future,
    );
    addTearDown(() async {
      await service.dispose();
      await changes.close();
    });

    final staleVerification = service.verify();
    await Future<void>.delayed(Duration.zero);
    changes.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    probe.complete(true);

    expect(await staleVerification, NetworkReachability.offline);
    expect(service.current, NetworkReachability.offline);
  });

  test('network switch ignores stale probe and accepts newest probe', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final probes = <Completer<bool>>[];
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.wifi],
      connectivityChanges: changes.stream,
      healthProbe: () {
        final probe = Completer<bool>();
        probes.add(probe);
        return probe.future;
      },
    );
    addTearDown(() async {
      await service.dispose();
      await changes.close();
    });

    final first = service.verify();
    await Future<void>.delayed(Duration.zero);
    changes.add(const [ConnectivityResult.mobile]);
    await Future<void>.delayed(Duration.zero);
    expect(probes, hasLength(2));

    probes.first.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(service.current, NetworkReachability.checking);
    probes.last.complete(false);

    expect(await first, NetworkReachability.checking);
    await Future<void>.delayed(Duration.zero);
    expect(service.current, NetworkReachability.unreachable);
  });

  test('successful API request invalidates an older failed probe', () async {
    final probe = Completer<bool>();
    final service = ConnectivityNetworkStatusService(
      checkConnectivity: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream.empty(),
      healthProbe: () => probe.future,
    );
    addTearDown(service.dispose);

    final verification = service.verify();
    await Future<void>.delayed(Duration.zero);
    service.markOnlineFromRequest();
    probe.complete(false);

    expect(await verification, NetworkReachability.online);
    expect(service.current, NetworkReachability.online);
  });
}
