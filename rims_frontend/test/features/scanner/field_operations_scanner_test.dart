import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/scanner/data/field_operations_scanner.dart';
import 'package:rims_frontend/features/scanner/domain/services/barcode_scanner_capability.dart';

void main() {
  test('production field-operation injection is disabled by default', () {
    expect(FieldOperationsTestConfig.current.enabled, isFalse);
    expect(FieldOperationsTestConfig.current.barcode, isEmpty);
  });

  test(
    'deterministic scanner denies once then emits one configured barcode',
    () async {
      final scanner = FieldOperationsScanner(
        barcode: 'M9-PAGE-0001',
        now: () => DateTime.utc(2026, 7, 13),
      );
      addTearDown(scanner.dispose);
      final scans = <String>[];
      final subscription = scanner.scans.listen(
        (scan) => scans.add(scan.value),
      );
      addTearDown(subscription.cancel);

      await scanner.start();
      expect(scanner.accessState, ScannerAccessState.permissionDenied);
      await scanner.start();
      await Future<void>.delayed(Duration.zero);

      expect(scanner.accessState, ScannerAccessState.ready);
      expect(scans, ['M9-PAGE-0001']);
      await scanner.start();
      await Future<void>.delayed(Duration.zero);
      expect(scans, ['M9-PAGE-0001']);
    },
  );
}
