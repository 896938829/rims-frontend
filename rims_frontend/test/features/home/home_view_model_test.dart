import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/home/presentation/pages/home_page.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  test('HomeViewModel exposes session context and dashboard data', () {
    const viewModel = HomeViewModel(user: _user, warehouse: _warehouse);

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.greeting, 'Good morning, 系统管理员');
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.quickActions, hasLength(4));
    expect(viewModel.warnings, hasLength(3));
    expect(viewModel.recentDocuments, hasLength(3));
  });

  testWidgets('HomePage does not overflow on narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(user: _user, warehouse: _warehouse),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

const _user = AppUser(
  id: 1,
  username: 'admin',
  realName: '系统管理员',
  roleCode: 'admin',
  roleName: '管理员',
);

const _warehouse = Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true);
