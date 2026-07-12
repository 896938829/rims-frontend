import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rims_frontend/main.dart';

import 'support/rims_e2e_driver.dart';

final IntegrationTestWidgetsFlutterBinding binding =
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

void main() {
  testWidgets('local acceptance journey', (tester) async {
    await screenshotOnFailure(
      binding,
      'local-acceptance-journey-failure',
      () async {
        await tester.pumpWidget(const MainApp());
        await waitForKey(tester, const Key('login-username-field'));
      },
    );
  });
}
