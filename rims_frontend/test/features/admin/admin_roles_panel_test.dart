import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/widgets/admin_roles_panel.dart';

void main() {
  testWidgets('AdminRolesPanel loads roles and saves permissions', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminRolesPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-admin-roles-panel')), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('admin-manage-role-permissions-1-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('查看库存'), findsOneWidget);
    expect(find.text('管理用户'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('admin-role-1-permission-2-checkbox')),
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-role-permissions-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.updateRolePermissionsRequest, isNull);
    expect(
      find.byKey(const Key('admin-confirm-save-role-permissions-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin-confirm-save-role-permissions-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.updateRolePermissionsRequest?.roleId, 1);
    expect(repository.updateRolePermissionsRequest?.permissionIds, [1, 2]);
  });

  testWidgets(
    'AdminRolesPanel closes confirmation and shows backend permission error',
    (tester) async {
      final repository = _FakeAdminRepository(
        updateRolePermissionsResult: const FailureResult<void>(
          AuthorizationFailure(message: '权限不足'),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminRolesPanel(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin-manage-role-permissions-1-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin-submit-role-permissions-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin-confirm-save-role-permissions-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.updateRolePermissionsRequest?.roleId, 1);
      expect(
        find.byKey(const Key('admin-confirm-save-role-permissions-button')),
        findsNothing,
      );
      expect(find.text('管理员 权限'), findsOneWidget);
      expect(find.text('权限不足'), findsWidgets);
    },
  );
}

const _adminRole = AdminRole(
  id: 1,
  code: 'admin',
  name: '管理员',
  status: 1,
  permissionIds: [1],
);

const _inventoryRead = AdminPermission(
  id: 1,
  code: 'inventory.read',
  name: '查看库存',
  group: '库存',
  description: '',
);

const _userManage = AdminPermission(
  id: 2,
  code: 'user.manage',
  name: '管理用户',
  group: '用户',
  description: '',
);

final class _FakeAdminRepository implements AdminRepository {
  _FakeAdminRepository({this.updateRolePermissionsResult});

  final Result<void>? updateRolePermissionsResult;
  UpdateRolePermissionsRequest? updateRolePermissionsRequest;

  @override
  Future<Result<List<AdminRole>>> listRoles() async {
    return const Success<List<AdminRole>>([_adminRole]);
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() async {
    return const Success<List<AdminPermission>>([_inventoryRead, _userManage]);
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) async {
    updateRolePermissionsRequest = request;
    return updateRolePermissionsResult ?? const Success<void>(null);
  }

  @override
  Future<Result<List<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<AdminUser>>([]);
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
  Future<Result<List<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<AdminProduct>>([]);
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
  Future<Result<List<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<AdminWarehouse>>([]);
  }

  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) {
    throw UnimplementedError();
  }

  @override
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) async {
    return const Success<List<AdminUser>>([]);
  }

  @override
  Future<Result<void>> bindWarehouseUsers(BindWarehouseUsersRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success(null));
  }
}
