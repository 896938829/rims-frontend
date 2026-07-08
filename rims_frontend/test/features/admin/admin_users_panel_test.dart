import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/widgets/admin_users_panel.dart';

void main() {
  testWidgets('AdminUsersPanel loads users and creates a test account', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminUsersPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-admin-users-panel')), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin-create-user-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-create-username-field')),
      'bob',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-password-field')),
      'Pwd@12345',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-real-name-field')),
      '李四',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-role-id-field')),
      '2',
    );
    await tester.tap(find.byKey(const Key('admin-submit-create-user-button')));
    await tester.pumpAndSettle();

    expect(repository.createdRequest?.username, 'bob');
    expect(repository.createdRequest?.roleId, 2);
    expect(find.text('bob'), findsOneWidget);
  });

  testWidgets('AdminUsersPanel rejects malformed create role id', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminUsersPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-create-user-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-create-username-field')),
      'bob',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-password-field')),
      'Pwd@12345',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-role-id-field')),
      'abc',
    );
    await tester.tap(find.byKey(const Key('admin-submit-create-user-button')));
    await tester.pumpAndSettle();

    expect(repository.createdRequest, isNull);
    expect(find.text('角色 ID 只能填写正整数'), findsOneWidget);
  });

  testWidgets(
    'AdminUsersPanel confirms before resetting selected user password',
    (tester) async {
      final repository = _FakeAdminRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminUsersPanel(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-reset-password-2-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin-reset-password-field')),
        'NewPwd@123',
      );
      await tester.tap(
        find.byKey(const Key('admin-submit-reset-password-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.resetPasswordRequest, isNull);
      expect(
        find.byKey(const Key('admin-confirm-reset-password-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('admin-confirm-reset-password-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.resetPasswordRequest?.userId, 2);
      expect(repository.resetPasswordRequest?.newPassword, 'NewPwd@123');
    },
  );

  testWidgets('AdminUsersPanel updates selected user', (tester) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminUsersPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-edit-user-2-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-edit-real-name-field')),
      '新名',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-phone-field')),
      '13900000000',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-email-field')),
      'new@b.com',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-role-id-field')),
      '3',
    );
    await tester.tap(find.byKey(const Key('admin-edit-status-switch')));
    await tester.tap(find.byKey(const Key('admin-submit-edit-user-button')));
    await tester.pumpAndSettle();

    expect(repository.updatedRequest?.id, 2);
    expect(repository.updatedRequest?.realName, '新名');
    expect(repository.updatedRequest?.roleId, 3);
    expect(repository.updatedRequest?.status, 0);
    expect(find.text('新名'), findsOneWidget);
  });

  testWidgets('AdminUsersPanel rejects malformed edit role id', (tester) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminUsersPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-edit-user-2-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-edit-role-id-field')),
      'abc',
    );
    await tester.tap(find.byKey(const Key('admin-submit-edit-user-button')));
    await tester.pumpAndSettle();

    expect(repository.updatedRequest, isNull);
    expect(find.text('角色 ID 只能填写正整数'), findsOneWidget);
  });

  testWidgets('AdminUsersPanel deletes selected user after confirmation', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminUsersPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-delete-user-2-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin-confirm-delete-user-button')));
    await tester.pumpAndSettle();

    expect(repository.deletedUserId, 2);
    expect(find.text('alice'), findsNothing);
  });
}

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

const _bob = AdminUser(
  id: 3,
  username: 'bob',
  realName: '李四',
  phone: '',
  email: '',
  roleId: 2,
  roleCode: 'user',
  roleName: '普通用户',
  status: 1,
);

const _updatedAlice = AdminUser(
  id: 2,
  username: 'alice',
  realName: '新名',
  phone: '13900000000',
  email: 'new@b.com',
  roleId: 3,
  roleCode: 'manager',
  roleName: '主管',
  status: 0,
);

final class _FakeAdminRepository implements AdminRepository {
  CreateAdminUserRequest? createdRequest;
  ResetUserPasswordRequest? resetPasswordRequest;
  UpdateAdminUserRequest? updatedRequest;
  int? deletedUserId;

  @override
  Future<Result<List<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<AdminUser>>([_alice]);
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) async {
    createdRequest = request;
    return const Success<AdminUser>(_bob);
  }

  @override
  Future<Result<void>> changeOwnPassword(
    ChangeOwnPasswordRequest request,
  ) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> resetUserPassword(
    ResetUserPasswordRequest request,
  ) async {
    resetPasswordRequest = request;
    return const Success<void>(null);
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) async {
    updatedRequest = request;
    return const Success<AdminUser>(_updatedAlice);
  }

  @override
  Future<Result<void>> deleteUser(int id) async {
    deletedUserId = id;
    return const Success<void>(null);
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
}
