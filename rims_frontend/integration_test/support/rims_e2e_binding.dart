import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';

final class RimsE2eBinding extends IntegrationTestWidgetsFlutterBinding {
  @override
  void postTest() {
    if (kIsWeb) {
      buildOwner!.focusManager.applyFocusChangesIfNeeded();
    }
    super.postTest();
  }
}
