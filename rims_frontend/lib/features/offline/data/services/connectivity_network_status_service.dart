import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../../domain/entities/network_reachability.dart';
import '../../domain/services/network_status_service.dart';

typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();
typedef HealthProbe = Future<bool> Function();

final class ConnectivityNetworkStatusService implements NetworkStatusService {
  ConnectivityNetworkStatusService({
    required this.checkConnectivity,
    required Stream<List<ConnectivityResult>> connectivityChanges,
    required this.healthProbe,
    this.probeTimeout = const Duration(seconds: 3),
  }) {
    _connectivitySubscription = connectivityChanges.listen(_handleConnectivity);
  }

  final ConnectivityCheck checkConnectivity;
  final HealthProbe healthProbe;
  final Duration probeTimeout;
  final StreamController<NetworkReachability> _changes =
      StreamController<NetworkReachability>.broadcast(sync: true);
  late final StreamSubscription<List<ConnectivityResult>>
  _connectivitySubscription;
  NetworkReachability _current = NetworkReachability.checking;
  var _generation = 0;
  var _disposed = false;

  @override
  NetworkReachability get current => _current;

  @override
  Stream<NetworkReachability> get changes => _changes.stream;

  @override
  Future<NetworkReachability> verify() async {
    final generation = ++_generation;
    final connectivity = await checkConnectivity();
    if (generation != _generation) return _current;
    return _verifyConnectivity(connectivity, generation);
  }

  @override
  void markOnlineFromRequest() {
    _generation += 1;
    _setCurrent(NetworkReachability.online);
  }

  Future<NetworkReachability> _verifyConnectivity(
    List<ConnectivityResult> connectivity,
    int generation,
  ) async {
    if (_isOffline(connectivity)) {
      _setCurrent(NetworkReachability.offline);
      return _current;
    }

    _setCurrent(NetworkReachability.checking);
    var reachable = false;
    try {
      reachable = await healthProbe().timeout(probeTimeout);
    } on Object {
      reachable = false;
    }
    if (generation != _generation) return _current;
    _setCurrent(
      reachable ? NetworkReachability.online : NetworkReachability.unreachable,
    );
    return _current;
  }

  void _handleConnectivity(List<ConnectivityResult> connectivity) {
    final generation = ++_generation;
    unawaited(_verifyConnectivity(connectivity, generation));
  }

  bool _isOffline(List<ConnectivityResult> connectivity) {
    return connectivity.isEmpty ||
        connectivity.every((result) => result == ConnectivityResult.none);
  }

  void _setCurrent(NetworkReachability next) {
    if (_disposed || _current == next) return;
    _current = next;
    _changes.add(next);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    await _connectivitySubscription.cancel();
    await _changes.close();
  }
}
