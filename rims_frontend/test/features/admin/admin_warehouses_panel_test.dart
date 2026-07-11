import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/widgets/admin_warehouses_panel.dart';

import 'admin_page_test_support.dart';

void main() {
  testWidgets('AdminWarehousesPanel loads warehouses and creates warehouse', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminWarehousesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('profile-admin-warehouses-panel')),
      findsOneWidget,
    );
    expect(find.text('上海仓'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin-create-warehouse-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-create-warehouse-code-field')),
      'BJ',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-warehouse-name-field')),
      '北京仓',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-warehouse-address-field')),
      '北京',
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-create-warehouse-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.createdWarehouseRequest?.code, 'BJ');
    expect(repository.createdWarehouseRequest?.name, '北京仓');
    expect(find.text('北京仓'), findsOneWidget);
  });

  testWidgets('AdminWarehousesPanel updates selected warehouse', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminWarehousesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-edit-warehouse-1-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-edit-warehouse-code-field')),
      'SH2',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-warehouse-name-field')),
      '上海二仓',
    );
    await tester.tap(
      find.byKey(const Key('admin-edit-warehouse-status-switch')),
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-edit-warehouse-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.updatedWarehouseRequest?.id, 1);
    expect(repository.updatedWarehouseRequest?.code, 'SH2');
    expect(repository.updatedWarehouseRequest?.status, 0);
    expect(find.text('上海二仓'), findsOneWidget);
  });

  testWidgets('AdminWarehousesPanel deletes selected warehouse', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminWarehousesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-delete-warehouse-1-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin-confirm-delete-warehouse-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.deletedWarehouseId, 1);
    expect(find.text('上海仓'), findsNothing);
  });

  testWidgets('AdminWarehousesPanel binds and unbinds warehouse users', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminWarehousesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin-manage-warehouse-users-1-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.listWarehouseUsersId, 1);
    expect(find.text('alice'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin-bind-warehouse-user-ids-field')),
      '3',
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-bind-warehouse-users-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.bindWarehouseUsersRequest?.warehouseId, 1);
    expect(repository.bindWarehouseUsersRequest?.userIds, [3]);

    await tester.tap(
      find.byKey(const Key('admin-unbind-warehouse-1-user-2-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.unboundWarehouseId, isNull);
    expect(repository.unboundUserId, isNull);
    expect(
      find.byKey(const Key('admin-confirm-unbind-warehouse-user-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin-confirm-unbind-warehouse-user-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.unboundWarehouseId, 1);
    expect(repository.unboundUserId, 2);
  });

  testWidgets('AdminWarehousesPanel rejects malformed warehouse user ids', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminWarehousesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin-manage-warehouse-users-1-button')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin-bind-warehouse-user-ids-field')),
      '3, abc',
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-bind-warehouse-users-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.bindWarehouseUsersRequest, isNull);
    expect(find.text('用户 ID 只能填写正整数'), findsOneWidget);
  });
}

const _shanghai = AdminWarehouse(
  id: 1,
  code: 'SH',
  name: '上海仓',
  status: 1,
  address: '上海',
  contactPerson: '王五',
  contactPhone: '13800000001',
);

const _beijing = AdminWarehouse(
  id: 2,
  code: 'BJ',
  name: '北京仓',
  status: 1,
  address: '北京',
  contactPerson: '赵六',
  contactPhone: '13800000002',
);

const _updatedShanghai = AdminWarehouse(
  id: 1,
  code: 'SH2',
  name: '上海二仓',
  status: 0,
  address: '上海二仓地址',
  contactPerson: '王五',
  contactPhone: '13800000001',
);

const _alice = AdminUser(
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

final class _FakeAdminRepository implements AdminRepository {
  final List<AdminWarehouse> _warehouses = [_shanghai];
  CreateAdminWarehouseRequest? createdWarehouseRequest;
  UpdateAdminWarehouseRequest? updatedWarehouseRequest;
  BindWarehouseUsersRequest? bindWarehouseUsersRequest;
  int? deletedWarehouseId;
  int? listWarehouseUsersId;
  int? unboundWarehouseId;
  int? unboundUserId;

  @override
  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(_warehouses));
  }

  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async {
    createdWarehouseRequest = request;
    _warehouses.insert(0, _beijing);
    return const Success<AdminWarehouse>(_beijing);
  }

  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async {
    updatedWarehouseRequest = request;
    _warehouses[_warehouses.indexWhere(
          (warehouse) => warehouse.id == _updatedShanghai.id,
        )] =
        _updatedShanghai;
    return const Success<AdminWarehouse>(_updatedShanghai);
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) async {
    deletedWarehouseId = id;
    _warehouses.removeWhere((warehouse) => warehouse.id == id);
    return const Success<void>(null);
  }

  @override
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) async {
    listWarehouseUsersId = warehouseId;
    return const Success<List<AdminUser>>([_alice]);
  }

  @override
  Future<Result<void>> bindWarehouseUsers(
    BindWarehouseUsersRequest request,
  ) async {
    bindWarehouseUsersRequest = request;
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) async {
    unboundWarehouseId = warehouseId;
    unboundUserId = userId;
    return const Success<void>(null);
  }

  @override
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(<AdminUser>[]));
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> deleteUser(int id) {
    throw UnimplementedError();
  }

  @override
  Future<Result<PageData<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(<AdminProduct>[]));
  }

  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> deleteProduct(int id) {
    throw UnimplementedError();
  }

  @override
  Future<Result<List<AdminRole>>> listRoles() async {
    return const Success<List<AdminRole>>([]);
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() async {
    return const Success<List<AdminPermission>>([]);
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
