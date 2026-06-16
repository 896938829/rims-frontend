import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/profile/presentation/view_models/profile_view_model.dart';

void main() {
  test('ProfileViewModel exposes static permission and API guard data', () {
    const viewModel = ProfileViewModel();

    expect(viewModel.userName, '张三');
    expect(viewModel.roleName, '普通用户');
    expect(viewModel.apiGuards, contains('JWT'));
    expect(viewModel.backendModules, contains('warehouse'));
    expect(viewModel.permissionGroups, hasLength(2));
  });
}
