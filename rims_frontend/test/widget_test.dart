import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/config/app_environment.dart';
import 'package:rims_frontend/main.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';

void main() {
  testWidgets('RIMS app renders login entry', (tester) async {
    await tester.pumpWidget(
      MainApp(
        offlineStore: MemoryOfflineStore(),
        configuration: AppConfiguration.localTest(),
        networkStatusService: _OnlineNetworkStatusService(),
      ),
    );
    await tester.pump();

    expect(find.text('RIMS'), findsWidgets);
    expect(find.text('登录'), findsWidgets);
  });

  testWidgets('production app keeps its existing light theme behavior', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(
      MainApp(
        offlineStore: MemoryOfflineStore(),
        configuration: AppConfiguration.localTest(),
        networkStatusService: _OnlineNetworkStatusService(),
      ),
    );
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.darkTheme, isNull);
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
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
