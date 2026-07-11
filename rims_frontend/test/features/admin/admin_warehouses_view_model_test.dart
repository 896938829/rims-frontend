import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/view_models/admin_warehouses_view_model.dart';

import 'admin_page_test_support.dart';

void main() {
  test('load exposes backend warehouses', () async {
    final pending = Completer<Result<List<AdminWarehouse>>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    expect(repository.lastWarehouseKeyword, '');

    pending.complete(const Success<List<AdminWarehouse>>([_shanghai]));
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.warehouses, [_shanghai]);
  });

  test('load completes without notifying after disposal', () async {
    final pending = Completer<Result<List<AdminWarehouse>>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    final loadFuture = viewModel.load();
    viewModel.dispose();
    pending.complete(const Success<List<AdminWarehouse>>([_shanghai]));

    await expectLater(loadFuture, completes);
  });

  test('reload failure keeps previously loaded warehouses', () async {
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([]),
      ),
      listWarehousesResults: [
        const Success<List<AdminWarehouse>>([_shanghai]),
        const FailureResult<List<AdminWarehouse>>(
          NetworkFailure(message: '仓库列表刷新失败'),
        ),
      ],
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '仓库列表刷新失败');
    expect(viewModel.warehouses, [_shanghai]);
    expect(viewModel.isEmpty, isFalse);
  });

  test(
    'createWarehouse validates required fields before repository call',
    () async {
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([]),
        ),
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);

      final created = await viewModel.createWarehouse(
        const CreateAdminWarehouseRequest(code: '', name: ''),
      );

      expect(created, isFalse);
      expect(viewModel.formError, '请填写仓库编码和名称');
      expect(repository.createdWarehouseRequest, isNull);
    },
  );

  test(
    'createWarehouse prepends created warehouse after backend success',
    () async {
      final pending = Completer<Result<AdminWarehouse>>();
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        createWarehouseResult: pending.future,
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);
      await viewModel.load();

      final createFuture = viewModel.createWarehouse(
        const CreateAdminWarehouseRequest(
          code: 'BJ',
          name: '北京仓',
          address: '北京',
        ),
      );

      expect(viewModel.isCreatingWarehouse, isTrue);
      pending.complete(const Success<AdminWarehouse>(_beijing));
      final created = await createFuture;

      expect(created, isTrue);
      expect(repository.createdWarehouseRequest?.code, 'BJ');
      expect(viewModel.isCreatingWarehouse, isFalse);
      expect(viewModel.formError, isNull);
      expect(viewModel.warehouses, [_beijing, _shanghai]);
    },
  );

  test('createWarehouse ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminWarehouse>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai]),
      ),
      createWarehouseResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);
    await viewModel.load();

    const request = CreateAdminWarehouseRequest(code: 'BJ', name: '北京仓');
    final createFuture = viewModel.createWarehouse(request);

    expect(viewModel.isCreatingWarehouse, isTrue);
    final duplicateFuture = viewModel.createWarehouse(request);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.createWarehouseCallCount;

    pending.complete(const Success<AdminWarehouse>(_beijing));
    expect(await createFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test(
    'updateWarehouse replaces matching warehouse after backend success',
    () async {
      final pending = Completer<Result<AdminWarehouse>>();
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        updateWarehouseResult: pending.future,
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);
      await viewModel.load();

      final updateFuture = viewModel.updateWarehouse(
        const UpdateAdminWarehouseRequest(
          id: 1,
          code: 'SH2',
          name: '上海二仓',
          status: 0,
        ),
      );

      expect(viewModel.isUpdatingWarehouse, isTrue);
      pending.complete(const Success<AdminWarehouse>(_updatedShanghai));
      final updated = await updateFuture;

      expect(updated, isTrue);
      expect(repository.updatedWarehouseRequest?.id, 1);
      expect(viewModel.isUpdatingWarehouse, isFalse);
      expect(viewModel.warehouses, [_updatedShanghai]);
    },
  );

  test('updateWarehouse ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminWarehouse>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai]),
      ),
      updateWarehouseResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);
    await viewModel.load();

    const request = UpdateAdminWarehouseRequest(
      id: 1,
      code: 'SH2',
      name: '上海二仓',
    );
    final updateFuture = viewModel.updateWarehouse(request);

    expect(viewModel.isUpdatingWarehouse, isTrue);
    final duplicateFuture = viewModel.updateWarehouse(request);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.updateWarehouseCallCount;

    pending.complete(const Success<AdminWarehouse>(_updatedShanghai));
    expect(await updateFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test(
    'deleteWarehouse exposes backend conflict and keeps warehouse',
    () async {
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        deleteWarehouseResult: Future.value(
          const FailureResult<void>(ConflictFailure(message: '仓库存在业务数据')),
        ),
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);
      await viewModel.load();

      final deleted = await viewModel.deleteWarehouse(_shanghai);

      expect(deleted, isFalse);
      expect(repository.deletedWarehouseId, 1);
      expect(viewModel.warehouseActionError, '仓库存在业务数据');
      expect(viewModel.warehouses, [_shanghai]);
    },
  );

  test('deleteWarehouse ignores duplicate submission while pending', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai, _beijing]),
      ),
      deleteWarehouseResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);
    await viewModel.load();

    final deleteFuture = viewModel.deleteWarehouse(_shanghai);

    expect(viewModel.isDeletingWarehouse, isTrue);
    final duplicateFuture = viewModel.deleteWarehouse(_shanghai);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.deleteWarehouseCallCount;

    pending.complete(const Success<void>(null));
    expect(await deleteFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('loadWarehouseUsers exposes bound users', () async {
    final pending = Completer<Result<List<AdminUser>>>();
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai]),
      ),
      listWarehouseUsersResult: pending.future,
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    final loadFuture = viewModel.loadWarehouseUsers(_shanghai);

    expect(viewModel.isLoadingWarehouseUsers, isTrue);
    pending.complete(const Success<List<AdminUser>>([_alice]));
    await loadFuture;

    expect(viewModel.isLoadingWarehouseUsers, isFalse);
    expect(repository.listWarehouseUsersId, 1);
    expect(viewModel.usersForWarehouse(1), [_alice]);
  });

  test('reload failure keeps previously loaded warehouse users', () async {
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai]),
      ),
      listWarehouseUsersResults: [
        const Success<List<AdminUser>>([_alice]),
        const FailureResult<List<AdminUser>>(
          NetworkFailure(message: '绑定用户刷新失败'),
        ),
      ],
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    await viewModel.loadWarehouseUsers(_shanghai);
    await viewModel.loadWarehouseUsers(_shanghai);

    expect(viewModel.isLoadingWarehouseUsers, isFalse);
    expect(viewModel.userBindingError, '绑定用户刷新失败');
    expect(viewModel.usersForWarehouse(1), [_alice]);
  });

  test(
    'bindWarehouseUsers validates user ids before repository call',
    () async {
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);

      final bound = await viewModel.bindWarehouseUsers(
        warehouse: _shanghai,
        userIds: const [],
      );

      expect(bound, isFalse);
      expect(viewModel.userBindingError, '请填写要绑定的用户 ID');
      expect(repository.bindWarehouseUsersRequest, isNull);
    },
  );

  test('bindWarehouseUsers submits request and reloads bound users', () async {
    final repository = _FakeAdminRepository(
      listWarehousesResult: Future.value(
        const Success<List<AdminWarehouse>>([_shanghai]),
      ),
      bindWarehouseUsersResult: Future.value(const Success<void>(null)),
      listWarehouseUsersResult: Future.value(
        const Success<List<AdminUser>>([_alice]),
      ),
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);

    final bound = await viewModel.bindWarehouseUsers(
      warehouse: _shanghai,
      userIds: const [2],
    );

    expect(bound, isTrue);
    expect(repository.bindWarehouseUsersRequest?.warehouseId, 1);
    expect(repository.bindWarehouseUsersRequest?.userIds, [2]);
    expect(viewModel.usersForWarehouse(1), [_alice]);
  });

  test(
    'bindWarehouseUsers publishes global refresh after backend success',
    () async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        bindWarehouseUsersResult: Future.value(const Success<void>(null)),
        listWarehouseUsersResult: Future.value(
          const Success<List<AdminUser>>([_alice]),
        ),
      );
      final viewModel = AdminWarehousesViewModel(
        repository: repository,
        eventBus: eventBus,
      );
      final refreshEvent = eventBus.on<GlobalRefreshRequestedEvent>().first;

      final bound = await viewModel.bindWarehouseUsers(
        warehouse: _shanghai,
        userIds: const [2],
      );

      expect(bound, isTrue);
      await expectLater(refreshEvent, completes);
    },
  );

  test(
    'bindWarehouseUsers ignores duplicate submission while pending',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        bindWarehouseUsersResult: pending.future,
        listWarehouseUsersResult: Future.value(
          const Success<List<AdminUser>>([_alice]),
        ),
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);

      final bindFuture = viewModel.bindWarehouseUsers(
        warehouse: _shanghai,
        userIds: const [2],
      );

      expect(viewModel.isBindingWarehouseUsers, isTrue);
      final duplicateFuture = viewModel.bindWarehouseUsers(
        warehouse: _shanghai,
        userIds: const [2],
      );
      await Future<void>.delayed(Duration.zero);
      final callCountDuringPending = repository.bindWarehouseUsersCallCount;

      pending.complete(const Success<void>(null));
      expect(await bindFuture, isTrue);
      expect(await duplicateFuture, isFalse);
      expect(callCountDuringPending, 1);
    },
  );

  test(
    'unbindWarehouseUser removes matching user after backend success',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        listWarehouseUsersResult: Future.value(
          const Success<List<AdminUser>>([_alice, _bob]),
        ),
        unbindWarehouseUserResult: pending.future,
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);
      await viewModel.loadWarehouseUsers(_shanghai);

      final unbindFuture = viewModel.unbindWarehouseUser(
        warehouse: _shanghai,
        user: _alice,
      );

      expect(viewModel.isUnbindingWarehouseUser, isTrue);
      pending.complete(const Success<void>(null));
      final unbound = await unbindFuture;

      expect(unbound, isTrue);
      expect(repository.unboundWarehouseId, 1);
      expect(repository.unboundUserId, 2);
      expect(viewModel.isUnbindingWarehouseUser, isFalse);
      expect(viewModel.usersForWarehouse(1), [_bob]);
    },
  );

  test(
    'unbindWarehouseUser ignores duplicate submission while pending',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listWarehousesResult: Future.value(
          const Success<List<AdminWarehouse>>([_shanghai]),
        ),
        listWarehouseUsersResult: Future.value(
          const Success<List<AdminUser>>([_alice, _bob]),
        ),
        unbindWarehouseUserResult: pending.future,
      );
      final viewModel = AdminWarehousesViewModel(repository: repository);
      await viewModel.loadWarehouseUsers(_shanghai);

      final unbindFuture = viewModel.unbindWarehouseUser(
        warehouse: _shanghai,
        user: _alice,
      );

      expect(viewModel.isUnbindingWarehouseUser, isTrue);
      final duplicateFuture = viewModel.unbindWarehouseUser(
        warehouse: _shanghai,
        user: _alice,
      );
      await Future<void>.delayed(Duration.zero);
      final callCountDuringPending = repository.unbindWarehouseUserCallCount;

      pending.complete(const Success<void>(null));
      expect(await unbindFuture, isTrue);
      expect(await duplicateFuture, isFalse);
      expect(callCountDuringPending, 1);
    },
  );
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

final class _FakeAdminRepository implements AdminRepository {
  _FakeAdminRepository({
    required this.listWarehousesResult,
    this.listWarehousesResults,
    this.createWarehouseResult,
    this.updateWarehouseResult,
    this.deleteWarehouseResult,
    this.listWarehouseUsersResult,
    this.listWarehouseUsersResults,
    this.bindWarehouseUsersResult,
    this.unbindWarehouseUserResult,
  });

  final Future<Result<List<AdminWarehouse>>> listWarehousesResult;
  final List<Result<List<AdminWarehouse>>>? listWarehousesResults;
  final Future<Result<AdminWarehouse>>? createWarehouseResult;
  final Future<Result<AdminWarehouse>>? updateWarehouseResult;
  final Future<Result<void>>? deleteWarehouseResult;
  final Future<Result<List<AdminUser>>>? listWarehouseUsersResult;
  final List<Result<List<AdminUser>>>? listWarehouseUsersResults;
  final Future<Result<void>>? bindWarehouseUsersResult;
  final Future<Result<void>>? unbindWarehouseUserResult;
  String? lastWarehouseKeyword;
  int? listWarehouseUsersId;
  CreateAdminWarehouseRequest? createdWarehouseRequest;
  UpdateAdminWarehouseRequest? updatedWarehouseRequest;
  BindWarehouseUsersRequest? bindWarehouseUsersRequest;
  int? deletedWarehouseId;
  int? unboundWarehouseId;
  int? unboundUserId;
  int createWarehouseCallCount = 0;
  int updateWarehouseCallCount = 0;
  int deleteWarehouseCallCount = 0;
  int bindWarehouseUsersCallCount = 0;
  int unbindWarehouseUserCallCount = 0;
  List<AdminWarehouse>? _serverWarehouses;

  @override
  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    lastWarehouseKeyword = keyword;
    final queuedResults = listWarehousesResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      final result = queuedResults.removeAt(0);
      result.when(
        success: (warehouses) => _serverWarehouses = List.of(warehouses),
        failure: (_) {},
      );
      return adminPageResult(result, page: page);
    }
    final serverWarehouses = _serverWarehouses;
    if (serverWarehouses != null) {
      return Success(adminPage(serverWarehouses, page: page));
    }
    final result = await listWarehousesResult;
    result.when(
      success: (warehouses) => _serverWarehouses = List.of(warehouses),
      failure: (_) {},
    );
    return adminPageResult(result, page: page);
  }

  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async {
    createWarehouseCallCount += 1;
    createdWarehouseRequest = request;
    final result =
        await (createWarehouseResult ?? Future.value(const Success(_beijing)));
    result.when(
      success: (warehouse) => _serverWarehouses?.insert(0, warehouse),
      failure: (_) {},
    );
    return result;
  }

  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async {
    updateWarehouseCallCount += 1;
    updatedWarehouseRequest = request;
    final result =
        await (updateWarehouseResult ??
            Future.value(const Success(_updatedShanghai)));
    result.when(
      success: (warehouse) {
        final index = _serverWarehouses?.indexWhere(
          (item) => item.id == warehouse.id,
        );
        if (index != null && index >= 0) _serverWarehouses![index] = warehouse;
      },
      failure: (_) {},
    );
    return result;
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) async {
    deleteWarehouseCallCount += 1;
    deletedWarehouseId = id;
    final result =
        await (deleteWarehouseResult ??
            Future.value(const Success<void>(null)));
    result.when(
      success: (_) =>
          _serverWarehouses?.removeWhere((warehouse) => warehouse.id == id),
      failure: (_) {},
    );
    return result;
  }

  @override
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) {
    listWarehouseUsersId = warehouseId;
    final queuedResults = listWarehouseUsersResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      return Future.value(queuedResults.removeAt(0));
    }
    return listWarehouseUsersResult ??
        Future.value(const Success<List<AdminUser>>([]));
  }

  @override
  Future<Result<void>> bindWarehouseUsers(BindWarehouseUsersRequest request) {
    bindWarehouseUsersCallCount += 1;
    bindWarehouseUsersRequest = request;
    return bindWarehouseUsersResult ?? Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) {
    unbindWarehouseUserCallCount += 1;
    unboundWarehouseId = warehouseId;
    unboundUserId = userId;
    return unbindWarehouseUserResult ?? Future.value(const Success<void>(null));
  }

  @override
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) {
    return Future.value(Success(adminPage(<AdminUser>[])));
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
  }) {
    return Future.value(Success(adminPage(<AdminProduct>[])));
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

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
