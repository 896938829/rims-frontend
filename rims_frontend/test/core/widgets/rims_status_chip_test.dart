import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/widgets/rims_status_chip.dart';

void main() {
  testWidgets('RimsStatusChip renders label and semantic kind', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RimsStatusChip(
            label: '低库存',
            kind: RimsStatusKind.warning,
          ),
        ),
      ),
    );

    expect(find.text('低库存'), findsOneWidget);
    expect(find.byType(RimsStatusChip), findsOneWidget);
  });
}
