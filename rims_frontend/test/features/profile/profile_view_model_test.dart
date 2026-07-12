import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/profile/presentation/pages/profile_page.dart';
import 'package:rims_frontend/features/profile/presentation/view_models/profile_view_model.dart';

import '../admin/admin_page_test_support.dart';

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
      warehouses: [
        Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
        Warehouse(id: 2, code: 'BJ', name: '北京仓', isDefault: false),
      ],
    );

    expect(viewModel.userName, '系统管理员');
    expect(viewModel.workId, 'ID 1');
    expect(viewModel.roleName, '管理员');
    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.canSwitchWarehouse, isTrue);
  });

  test(
    'ProfileViewModel allows admin switching when user has multiple warehouses',
    () {
      const viewModel = ProfileViewModel(
        user: AppUser(
          id: 1,
          username: 'admin',
          realName: '系统管理员',
          roleCode: 'admin',
          roleName: '管理员',
        ),
        warehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
        warehouses: [
          Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
          Warehouse(id: 2, code: 'BJ', name: '北京仓', isDefault: false),
        ],
      );

      expect(viewModel.canSwitchWarehouse, isTrue);
    },
  );

  test(
    'ProfileViewModel prevents ordinary user switching even with multiple warehouses',
    () {
      const viewModel = ProfileViewModel(
        user: AppUser(
          id: 2,
          username: 'operator',
          realName: '库管员',
          roleCode: 'user',
          roleName: '普通用户',
        ),
        warehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
        warehouses: [
          Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
          Warehouse(id: 2, code: 'BJ', name: '北京仓', isDefault: false),
        ],
      );

      expect(viewModel.canSwitchWarehouse, isFalse);
    },
  );

  test(
    'ProfileViewModel prevents switching when only one warehouse exists',
    () {
      const viewModel = ProfileViewModel(
        user: AppUser(
          id: 2,
          username: 'operator',
          realName: '库管员',
          roleCode: 'user',
          roleName: '普通用户',
        ),
        warehouse: Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
        warehouses: [
          Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true),
        ],
      );

      expect(viewModel.canSwitchWarehouse, isFalse);
    },
  );

  testWidgets('ProfilePage shows admin management panels for admin', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePage(
            user: _adminUser,
            warehouse: _warehouse,
            adminRepository: _FakeAdminRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-admin-users')), findsOneWidget);
    expect(find.byKey(const Key('profile-admin-users-panel')), findsOneWidget);
    expect(find.text('用户管理'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('profile-admin-products-panel')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('profile-admin-products')), findsOneWidget);
    expect(find.text('商品管理'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-admin-warehouses-panel')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const Key('profile-admin-warehouses-panel')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('profile-admin-warehouses')), findsOneWidget);
    expect(find.text('仓库管理'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-admin-roles-panel')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('profile-admin-roles-panel')), findsOneWidget);
    expect(find.text('角色权限'), findsOneWidget);
  });

  testWidgets('ProfilePage hides admin management panels for ordinary user', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePage(
            user: _ordinaryUser,
            warehouse: _warehouse,
            adminRepository: _FakeAdminRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-admin-users-panel')), findsNothing);
    expect(find.byKey(const Key('profile-admin-products-panel')), findsNothing);
    expect(
      find.byKey(const Key('profile-admin-warehouses-panel')),
      findsNothing,
    );
    expect(find.byKey(const Key('profile-admin-roles-panel')), findsNothing);
    expect(find.text('用户管理'), findsNothing);
    expect(find.text('商品管理'), findsNothing);
    expect(find.text('仓库管理'), findsNothing);
    expect(find.text('角色权限'), findsNothing);
  });

  testWidgets('ProfilePage hides warehouse selector for ordinary user', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProfilePage(
            user: _ordinaryUser,
            warehouse: _warehouse,
            warehouses: [_warehouse, _beijingWarehouse],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-warehouse-selector')), findsNothing);
    expect(find.text('当前仓库'), findsOneWidget);
    expect(find.text('上海仓'), findsOneWidget);
    expect(find.text('切换仓库'), findsNothing);
  });

  testWidgets('ProfilePage does not show unsupported notification status', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProfilePage(user: _ordinaryUser, warehouse: _warehouse),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('通知设置'), findsNothing);
    expect(find.text('已开启'), findsNothing);
  });

  testWidgets('ProfilePage hides developer-only static capability panels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProfilePage(user: _ordinaryUser, warehouse: _warehouse),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('API 守卫'), findsNothing);
    expect(find.text('后端模块'), findsNothing);
    expect(find.text('角色与权限'), findsNothing);
    expect(find.text('JWT'), findsNothing);
    expect(find.text('X-Warehouse-ID'), findsNothing);
    expect(find.text('拥有系统配置、权限分配与全仓业务管理能力'), findsNothing);
  });

  testWidgets('ProfilePage lets current user change password', (tester) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePage(
            user: _ordinaryUser,
            warehouse: _warehouse,
            adminRepository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-change-password-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profile-old-password-field')),
      'old-secret',
    );
    await tester.enterText(
      find.byKey(const Key('profile-new-password-field')),
      'new-secret',
    );
    await tester.enterText(
      find.byKey(const Key('profile-confirm-password-field')),
      'new-secret',
    );
    await tester.tap(
      find.byKey(const Key('profile-submit-change-password-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.changePasswordRequest?.oldPassword, 'old-secret');
    expect(repository.changePasswordRequest?.newPassword, 'new-secret');
  });
}

const _adminUser = AppUser(
  id: 1,
  username: 'admin',
  realName: '系统管理员',
  roleCode: 'admin',
  roleName: '管理员',
);

const _ordinaryUser = AppUser(
  id: 2,
  username: 'operator',
  realName: '库管员',
  roleCode: 'user',
  roleName: '普通用户',
);

const _warehouse = Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true);

const _beijingWarehouse = Warehouse(
  id: 2,
  code: 'BJ',
  name: '北京仓',
  isDefault: false,
);

const _adminListUser = AdminUser(
  id: 2,
  username: 'alice',
  realName: '张三',
  phone: '',
  email: '',
  roleId: 2,
  roleCode: 'user',
  roleName: '普通用户',
  status: 1,
);

const _adminListProduct = AdminProduct(
  id: 10,
  code: 'SKU-WA-550',
  name: '矿泉水 550ml',
  unit: '瓶',
  category: '饮料',
  spec: '550ml',
  barcode: '',
  retailPrice: 3.5,
  costPrice: 1.2,
  imageUrl: '',
  status: 1,
);

const _adminListWarehouse = AdminWarehouse(
  id: 1,
  code: 'SH',
  name: '上海仓',
  status: 1,
  address: '上海',
  contactPerson: '王五',
  contactPhone: '13800000001',
);

const _adminListRole = AdminRole(
  id: 1,
  code: 'admin',
  name: '管理员',
  status: 1,
  permissionIds: [1],
);

const _adminListPermission = AdminPermission(
  id: 1,
  code: 'inventory.read',
  name: '查看库存',
  group: '库存',
  description: '',
);

final class _FakeAdminRepository implements AdminRepository {
  ChangeOwnPasswordRequest? changePasswordRequest;
  ResetUserPasswordRequest? resetPasswordRequest;

  @override
  Future<Result<PageData<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage([_adminListProduct]));
  }

  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) async {
    return const Success<AdminProduct>(_adminListProduct);
  }

  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) async {
    return const Success<AdminProduct>(_adminListProduct);
  }

  @override
  Future<Result<void>> deleteProduct(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage([_adminListWarehouse]));
  }

  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async {
    return const Success<AdminWarehouse>(_adminListWarehouse);
  }

  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async {
    return const Success<AdminWarehouse>(_adminListWarehouse);
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<PageData<AdminUser>>> listWarehouseUsers(
    int warehouseId, {
    int page = 1,
  }) async {
    return Success(adminPage([_adminListUser], page: page));
  }

  @override
  Future<Result<void>> bindWarehouseUsers(
    BindWarehouseUsersRequest request,
  ) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<List<AdminRole>>> listRoles() async {
    return const Success<List<AdminRole>>([_adminListRole]);
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() async {
    return const Success<List<AdminPermission>>([_adminListPermission]);
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage([_adminListUser]));
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) async {
    return const Success<AdminUser>(_adminListUser);
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) async {
    return const Success<AdminUser>(_adminListUser);
  }

  @override
  Future<Result<void>> deleteUser(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> changeOwnPassword(
    ChangeOwnPasswordRequest request,
  ) async {
    changePasswordRequest = request;
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> resetUserPassword(
    ResetUserPasswordRequest request,
  ) async {
    resetPasswordRequest = request;
    return const Success<void>(null);
  }
}
