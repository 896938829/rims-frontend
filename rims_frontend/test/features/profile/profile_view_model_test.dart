import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/profile/presentation/view_models/profile_view_model.dart';

void main() {
  test('ProfileViewModel exposes session user and warehouse data', () {
    const viewModel = ProfileViewModel(
      user: AppUser(
        id: 1,
        username: 'admin',
        realName: '系统管理员',
        roleCode: 'admin',
        roleName: '管理员',
      ),
      warehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
    );

    expect(viewModel.userName, '系统管理员');
    expect(viewModel.workId, 'ID 1');
    expect(viewModel.roleName, '管理员');
    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.canSwitchWarehouse, isTrue);
    expect(viewModel.apiGuards, contains('JWT'));
    expect(viewModel.backendModules, contains('warehouse'));
    expect(viewModel.permissionGroups, hasLength(2));
  });
}
