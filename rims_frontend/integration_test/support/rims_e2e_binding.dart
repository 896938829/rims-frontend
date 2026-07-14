import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';

final class RimsE2eBinding extends IntegrationTestWidgetsFlutterBinding {
  @override
  Future<void> runTest(
    Future<void> Function() testBody,
    VoidCallback invariantTester, {
    String description = '',
    Duration? timeout,
  }) async {
    await super.runTest(testBody, invariantTester, description: description);
    if (kIsWeb) {
      await Future<void>.delayed(Duration.zero);
      buildOwner!.focusManager.applyFocusChangesIfNeeded();
    }
  }
}
