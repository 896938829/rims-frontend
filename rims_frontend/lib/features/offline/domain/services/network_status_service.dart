import '../entities/network_reachability.dart';

abstract interface class NetworkStatusService {
  NetworkReachability get current;

  Stream<NetworkReachability> get changes;

  Future<NetworkReachability> verify();
}
