import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/home/presentation/pages/home_page.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  test('HomeViewModel exposes static dashboard data', () {
    const viewModel = HomeViewModel();

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.quickActions, hasLength(4));
    expect(viewModel.warnings, hasLength(3));
    expect(viewModel.recentDocuments, hasLength(3));
  });

  testWidgets('HomePage does not overflow on narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
