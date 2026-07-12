import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/main.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';

void main() {
  testWidgets('RIMS app renders login entry', (tester) async {
    await tester.pumpWidget(
      MainApp(
        offlineStore: MemoryOfflineStore(),
        networkStatusService: _OnlineNetworkStatusService(),
      ),
    );
    await tester.pump();

    expect(find.text('RIMS'), findsWidgets);
    expect(find.text('登录'), findsWidgets);
  });
}

final class _OnlineNetworkStatusService implements NetworkStatusService {
  @override
  NetworkReachability get current => NetworkReachability.online;

  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  Future<NetworkReachability> verify() async => NetworkReachability.online;

  @override
  void markOnlineFromRequest() {}

  @override
  Future<void> dispose() async {}
}
