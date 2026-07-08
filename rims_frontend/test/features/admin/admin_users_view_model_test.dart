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
import 'package:rims_frontend/features/admin/presentation/view_models/admin_users_view_model.dart';

void main() {
  test('load exposes backend users', () async {
    final pending = Completer<Result<List<AdminUser>>>();
    final repository = _FakeAdminRepository(listResult: pending.future);
    final viewModel = AdminUsersViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    expect(repository.lastKeyword, '');

    pending.complete(const Success<List<AdminUser>>([_alice]));
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.users, [_alice]);
  });

  test('load completes without notifying after disposal', () async {
    final pending = Completer<Result<List<AdminUser>>>();
    final repository = _FakeAdminRepository(listResult: pending.future);
    final viewModel = AdminUsersViewModel(repository: repository);

    final loadFuture = viewModel.load();
    viewModel.dispose();
    pending.complete(const Success<List<AdminUser>>([_alice]));

    await expectLater(loadFuture, completes);
  });

  test('reload failure keeps previously loaded users', () async {
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([])),
      listResults: [
        const Success<List<AdminUser>>([_alice]),
        const FailureResult<List<AdminUser>>(
          NetworkFailure(message: '用户列表刷新失败'),
        ),
      ],
    );
    final viewModel = AdminUsersViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '用户列表刷新失败');
    expect(viewModel.users, [_alice]);
    expect(viewModel.isEmpty, isFalse);
  });

  test('updateQuery reloads users with keyword', () async {
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
    );
    final viewModel = AdminUsersViewModel(repository: repository);

    await viewModel.updateQuery('alice');

    expect(viewModel.query, 'alice');
    expect(repository.lastKeyword, 'alice');
    expect(viewModel.users, [_alice]);
  });

  test(
    'createUser validates required fields before calling repository',
    () async {
      final repository = _FakeAdminRepository(
        listResult: Future.value(const Success<List<AdminUser>>([])),
      );
      final viewModel = AdminUsersViewModel(repository: repository);

      final created = await viewModel.createUser(
        const CreateAdminUserRequest(username: '', password: '', roleId: 0),
      );

      expect(created, isFalse);
      expect(viewModel.formError, '请填写用户名、密码和角色 ID');
      expect(repository.createdRequest, isNull);
    },
  );

  test('createUser prepends created backend user', () async {
    final pending = Completer<Result<AdminUser>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      createResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final createFuture = viewModel.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        realName: '李四',
        roleId: 2,
      ),
    );

    expect(viewModel.isCreatingUser, isTrue);
    pending.complete(const Success<AdminUser>(_bob));
    final created = await createFuture;

    expect(created, isTrue);
    expect(repository.createdRequest?.username, 'bob');
    expect(viewModel.isCreatingUser, isFalse);
    expect(viewModel.formError, isNull);
    expect(viewModel.users, [_bob, _alice]);
  });

  test('createUser publishes global refresh after backend success', () async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
    );
    final viewModel = AdminUsersViewModel(
      repository: repository,
      eventBus: eventBus,
    );
    await viewModel.load();
    final refreshEvent = eventBus.on<GlobalRefreshRequestedEvent>().first;

    final created = await viewModel.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );

    expect(created, isTrue);
    await expectLater(refreshEvent, completes);
  });

  test('createUser ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminUser>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      createResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final createFuture = viewModel.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );

    expect(viewModel.isCreatingUser, isTrue);
    final duplicateFuture = viewModel.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.createUserCallCount;

    pending.complete(const Success<AdminUser>(_bob));
    expect(await createFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('createUser exposes backend failure', () async {
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([])),
      createResult: Future.value(
        const FailureResult<AdminUser>(ValidationFailure(message: '用户名已存在')),
      ),
    );
    final viewModel = AdminUsersViewModel(repository: repository);

    final created = await viewModel.createUser(
      const CreateAdminUserRequest(
        username: 'alice',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );

    expect(created, isFalse);
    expect(viewModel.formError, '用户名已存在');
  });

  test(
    'resetUserPassword validates password before calling repository',
    () async {
      final repository = _FakeAdminRepository(
        listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      );
      final viewModel = AdminUsersViewModel(repository: repository);

      final reset = await viewModel.resetUserPassword(
        userId: 2,
        newPassword: '',
      );

      expect(reset, isFalse);
      expect(viewModel.passwordActionError, '请填写新密码');
      expect(repository.resetPasswordRequest, isNull);
    },
  );

  test('resetUserPassword submits backend reset request', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      resetPasswordResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);

    final resetFuture = viewModel.resetUserPassword(
      userId: 2,
      newPassword: 'NewPwd@123',
    );

    expect(viewModel.isResettingPassword, isTrue);
    pending.complete(const Success<void>(null));
    final reset = await resetFuture;

    expect(reset, isTrue);
    expect(repository.resetPasswordRequest?.userId, 2);
    expect(repository.resetPasswordRequest?.newPassword, 'NewPwd@123');
    expect(viewModel.isResettingPassword, isFalse);
    expect(viewModel.passwordActionError, isNull);
  });

  test(
    'resetUserPassword ignores duplicate submission while pending',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listResult: Future.value(const Success<List<AdminUser>>([_alice])),
        resetPasswordResult: pending.future,
      );
      final viewModel = AdminUsersViewModel(repository: repository);

      final resetFuture = viewModel.resetUserPassword(
        userId: 2,
        newPassword: 'NewPwd@123',
      );

      expect(viewModel.isResettingPassword, isTrue);
      final duplicateFuture = viewModel.resetUserPassword(
        userId: 2,
        newPassword: 'NewPwd@123',
      );
      await Future<void>.delayed(Duration.zero);
      final callCountDuringPending = repository.resetPasswordCallCount;

      pending.complete(const Success<void>(null));
      expect(await resetFuture, isTrue);
      expect(await duplicateFuture, isFalse);
      expect(callCountDuringPending, 1);
    },
  );

  test('updateUser validates role id before calling repository', () async {
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
    );
    final viewModel = AdminUsersViewModel(repository: repository);

    final updated = await viewModel.updateUser(
      const UpdateAdminUserRequest(id: 2, realName: '新名', roleId: 0),
    );

    expect(updated, isFalse);
    expect(viewModel.formError, '请填写有效角色 ID');
    expect(repository.updatedRequest, isNull);
  });

  test('updateUser replaces matching user after backend success', () async {
    final pending = Completer<Result<AdminUser>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      updateResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final updateFuture = viewModel.updateUser(
      const UpdateAdminUserRequest(
        id: 2,
        realName: '新名',
        phone: '13900000000',
        email: 'new@b.com',
        roleId: 3,
        status: 0,
      ),
    );

    expect(viewModel.isUpdatingUser, isTrue);
    pending.complete(const Success<AdminUser>(_updatedAlice));
    final updated = await updateFuture;

    expect(updated, isTrue);
    expect(repository.updatedRequest?.id, 2);
    expect(viewModel.isUpdatingUser, isFalse);
    expect(viewModel.formError, isNull);
    expect(viewModel.users, [_updatedAlice]);
  });

  test('updateUser ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminUser>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      updateResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    const request = UpdateAdminUserRequest(id: 2, realName: '新名', roleId: 3);
    final updateFuture = viewModel.updateUser(request);

    expect(viewModel.isUpdatingUser, isTrue);
    final duplicateFuture = viewModel.updateUser(request);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.updateUserCallCount;

    pending.complete(const Success<AdminUser>(_updatedAlice));
    expect(await updateFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('deleteUser removes matching user after backend success', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice, _bob])),
      deleteResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final deleteFuture = viewModel.deleteUser(_alice);

    expect(viewModel.isDeletingUser, isTrue);
    pending.complete(const Success<void>(null));
    final deleted = await deleteFuture;

    expect(deleted, isTrue);
    expect(repository.deletedUserId, 2);
    expect(viewModel.isDeletingUser, isFalse);
    expect(viewModel.userActionError, isNull);
    expect(viewModel.users, [_bob]);
  });

  test('deleteUser ignores duplicate submission while pending', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice, _bob])),
      deleteResult: pending.future,
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final deleteFuture = viewModel.deleteUser(_alice);

    expect(viewModel.isDeletingUser, isTrue);
    final duplicateFuture = viewModel.deleteUser(_alice);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.deleteUserCallCount;

    pending.complete(const Success<void>(null));
    expect(await deleteFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('deleteUser exposes backend conflict', () async {
    final repository = _FakeAdminRepository(
      listResult: Future.value(const Success<List<AdminUser>>([_alice])),
      deleteResult: Future.value(
        const FailureResult<void>(ConflictFailure(message: '用户存在业务数据')),
      ),
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();

    final deleted = await viewModel.deleteUser(_alice);

    expect(deleted, isFalse);
    expect(viewModel.userActionError, '用户存在业务数据');
    expect(viewModel.users, [_alice]);
  });
}

const _alice = AdminUser(
  id: 2,
  username: 'alice',
  realName: '张三',
  phone: '13800000000',
  email: 'a@b.com',
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
  _FakeAdminRepository({
    required this.listResult,
    this.listResults,
    this.createResult,
    this.resetPasswordResult,
    this.updateResult,
    this.deleteResult,
  });

  final Future<Result<List<AdminUser>>> listResult;
  final List<Result<List<AdminUser>>>? listResults;
  final Future<Result<AdminUser>>? createResult;
  final Future<Result<void>>? resetPasswordResult;
  final Future<Result<AdminUser>>? updateResult;
  final Future<Result<void>>? deleteResult;
  String? lastKeyword;
  CreateAdminUserRequest? createdRequest;
  ResetUserPasswordRequest? resetPasswordRequest;
  UpdateAdminUserRequest? updatedRequest;
  int? deletedUserId;
  int createUserCallCount = 0;
  int updateUserCallCount = 0;
  int resetPasswordCallCount = 0;
  int deleteUserCallCount = 0;

  @override
  Future<Result<List<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) {
    lastKeyword = keyword;
    final queuedResults = listResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      return Future.value(queuedResults.removeAt(0));
    }
    return listResult;
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) {
    createUserCallCount += 1;
    createdRequest = request;
    return createResult ?? Future.value(const Success<AdminUser>(_bob));
  }

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    resetPasswordCallCount += 1;
    resetPasswordRequest = request;
    return resetPasswordResult ?? Future.value(const Success<void>(null));
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) {
    updateUserCallCount += 1;
    updatedRequest = request;
    return updateResult ??
        Future.value(const Success<AdminUser>(_updatedAlice));
  }

  @override
  Future<Result<void>> deleteUser(int id) {
    deleteUserCallCount += 1;
    deletedUserId = id;
    return deleteResult ?? Future.value(const Success<void>(null));
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
  Future<Result<List<AdminRole>>> listRoles() {
    return Future.value(const Success<List<AdminRole>>([]));
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() {
    return Future.value(const Success<List<AdminPermission>>([]));
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) {
    return Future.value(const Success<void>(null));
  }
}
