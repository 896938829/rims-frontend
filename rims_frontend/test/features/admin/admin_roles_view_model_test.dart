import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/view_models/admin_roles_view_model.dart';

void main() {
  test('load exposes backend roles and permissions', () async {
    final pendingRoles = Completer<Result<List<AdminRole>>>();
    final pendingPermissions = Completer<Result<List<AdminPermission>>>();
    final repository = _FakeAdminRepository(
      listRolesResult: pendingRoles.future,
      listPermissionsResult: pendingPermissions.future,
    );
    final viewModel = AdminRolesViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    pendingRoles.complete(const Success<List<AdminRole>>([_adminRole]));
    pendingPermissions.complete(
      const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
    );
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.roles, [_adminRole]);
    expect(viewModel.permissions, [_inventoryRead, _userManage]);
  });

  test('load completes without notifying after disposal', () async {
    final pendingRoles = Completer<Result<List<AdminRole>>>();
    final pendingPermissions = Completer<Result<List<AdminPermission>>>();
    final repository = _FakeAdminRepository(
      listRolesResult: pendingRoles.future,
      listPermissionsResult: pendingPermissions.future,
    );
    final viewModel = AdminRolesViewModel(repository: repository);

    final loadFuture = viewModel.load();
    viewModel.dispose();
    pendingRoles.complete(const Success<List<AdminRole>>([_adminRole]));
    pendingPermissions.complete(
      const Success<List<AdminPermission>>([_inventoryRead]),
    );

    await expectLater(loadFuture, completes);
  });

  test(
    'roles reload failure keeps previously loaded roles and permissions',
    () async {
      final repository = _FakeAdminRepository(
        listRolesResult: Future.value(const Success<List<AdminRole>>([])),
        listPermissionsResult: Future.value(
          const Success<List<AdminPermission>>([]),
        ),
        listRolesResults: [
          const Success<List<AdminRole>>([_adminRole]),
          const FailureResult<List<AdminRole>>(
            NetworkFailure(message: '角色列表刷新失败'),
          ),
        ],
        listPermissionsResults: [
          const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
        ],
      );
      final viewModel = AdminRolesViewModel(repository: repository);

      await viewModel.load();
      await viewModel.load();

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.errorMessage, '角色列表刷新失败');
      expect(viewModel.roles, [_adminRole]);
      expect(viewModel.permissions, [_inventoryRead, _userManage]);
      expect(viewModel.isEmpty, isFalse);
    },
  );

  test(
    'permissions reload failure keeps previously loaded permissions',
    () async {
      final repository = _FakeAdminRepository(
        listRolesResult: Future.value(const Success<List<AdminRole>>([])),
        listPermissionsResult: Future.value(
          const Success<List<AdminPermission>>([]),
        ),
        listRolesResults: [
          const Success<List<AdminRole>>([_adminRole]),
          const Success<List<AdminRole>>([_adminRole]),
        ],
        listPermissionsResults: [
          const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
          const FailureResult<List<AdminPermission>>(
            NetworkFailure(message: '权限列表刷新失败'),
          ),
        ],
      );
      final viewModel = AdminRolesViewModel(repository: repository);

      await viewModel.load();
      await viewModel.load();

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.errorMessage, '权限列表刷新失败');
      expect(viewModel.roles, [_adminRole]);
      expect(viewModel.permissions, [_inventoryRead, _userManage]);
    },
  );

  test(
    'saveRolePermissions updates matching role after backend success',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listRolesResult: Future.value(
          const Success<List<AdminRole>>([_userRole]),
        ),
        listPermissionsResult: Future.value(
          const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
        ),
        updateRolePermissionsResult: pending.future,
      );
      final viewModel = AdminRolesViewModel(repository: repository);
      await viewModel.load();

      final saveFuture = viewModel.saveRolePermissions(
        role: _userRole,
        permissionIds: const [1, 2],
      );

      expect(viewModel.isSavingPermissions, isTrue);
      pending.complete(const Success<void>(null));
      final saved = await saveFuture;

      expect(saved, isTrue);
      expect(repository.updateRolePermissionsRequest?.roleId, 2);
      expect(repository.updateRolePermissionsRequest?.permissionIds, [1, 2]);
      expect(viewModel.isSavingPermissions, isFalse);
      expect(viewModel.permissionActionError, isNull);
      expect(viewModel.roles.single.permissionIds, [1, 2]);
    },
  );

  test(
    'saveRolePermissions publishes global refresh after backend success',
    () async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      final repository = _FakeAdminRepository(
        listRolesResult: Future.value(
          const Success<List<AdminRole>>([_userRole]),
        ),
        listPermissionsResult: Future.value(
          const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
        ),
      );
      final viewModel = AdminRolesViewModel(
        repository: repository,
        eventBus: eventBus,
      );
      await viewModel.load();
      final refreshEvent = eventBus.on<GlobalRefreshRequestedEvent>().first;

      final saved = await viewModel.saveRolePermissions(
        role: _userRole,
        permissionIds: const [1, 2],
      );

      expect(saved, isTrue);
      await expectLater(refreshEvent, completes);
    },
  );

  test(
    'saveRolePermissions ignores duplicate submission while pending',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listRolesResult: Future.value(
          const Success<List<AdminRole>>([_userRole]),
        ),
        listPermissionsResult: Future.value(
          const Success<List<AdminPermission>>([_inventoryRead, _userManage]),
        ),
        updateRolePermissionsResult: pending.future,
      );
      final viewModel = AdminRolesViewModel(repository: repository);
      await viewModel.load();

      final saveFuture = viewModel.saveRolePermissions(
        role: _userRole,
        permissionIds: const [1, 2],
      );

      expect(viewModel.isSavingPermissions, isTrue);
      final duplicateFuture = viewModel.saveRolePermissions(
        role: _userRole,
        permissionIds: const [1, 2],
      );
      await Future<void>.delayed(Duration.zero);
      final callCountDuringPending = repository.updateRolePermissionsCallCount;

      pending.complete(const Success<void>(null));
      expect(await saveFuture, isTrue);
      expect(await duplicateFuture, isFalse);
      expect(callCountDuringPending, 1);
    },
  );

  test('saveRolePermissions exposes backend failure and keeps role', () async {
    final repository = _FakeAdminRepository(
      listRolesResult: Future.value(
        const Success<List<AdminRole>>([_userRole]),
      ),
      listPermissionsResult: Future.value(
        const Success<List<AdminPermission>>([_inventoryRead]),
      ),
      updateRolePermissionsResult: Future.value(
        const FailureResult<void>(AuthorizationFailure(message: '权限不足')),
      ),
    );
    final viewModel = AdminRolesViewModel(repository: repository);
    await viewModel.load();

    final saved = await viewModel.saveRolePermissions(
      role: _userRole,
      permissionIds: const [1],
    );

    expect(saved, isFalse);
    expect(viewModel.permissionActionError, '权限不足');
    expect(viewModel.roles.single.permissionIds, isEmpty);
  });
}

const _adminRole = AdminRole(
  id: 1,
  code: 'admin',
  name: '管理员',
  status: 1,
  permissionIds: [1, 2],
);

const _userRole = AdminRole(
  id: 2,
  code: 'user',
  name: '普通用户',
  status: 1,
  permissionIds: [],
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
  _FakeAdminRepository({
    required this.listRolesResult,
    required this.listPermissionsResult,
    this.listRolesResults,
    this.listPermissionsResults,
    this.updateRolePermissionsResult,
  });

  final Future<Result<List<AdminRole>>> listRolesResult;
  final Future<Result<List<AdminPermission>>> listPermissionsResult;
  final List<Result<List<AdminRole>>>? listRolesResults;
  final List<Result<List<AdminPermission>>>? listPermissionsResults;
  final Future<Result<void>>? updateRolePermissionsResult;
  UpdateRolePermissionsRequest? updateRolePermissionsRequest;
  int updateRolePermissionsCallCount = 0;

  @override
  Future<Result<List<AdminRole>>> listRoles() {
    final queuedResults = listRolesResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      return Future.value(queuedResults.removeAt(0));
    }
    return listRolesResult;
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() {
    final queuedResults = listPermissionsResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      return Future.value(queuedResults.removeAt(0));
    }
    return listPermissionsResult;
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) {
    updateRolePermissionsCallCount += 1;
    updateRolePermissionsRequest = request;
    return updateRolePermissionsResult ?? Future.value(const Success(null));
  }

  @override
  Future<Result<List<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) {
    return Future.value(const Success<List<AdminUser>>([]));
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
  }) {
    return Future.value(const Success<List<AdminProduct>>([]));
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
  }) {
    return Future.value(const Success<List<AdminWarehouse>>([]));
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
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) {
    return Future.value(const Success<List<AdminUser>>([]));
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
