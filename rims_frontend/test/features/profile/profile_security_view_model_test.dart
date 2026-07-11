import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/profile/presentation/view_models/profile_security_view_model.dart';

import '../admin/admin_page_test_support.dart';

void main() {
  test('changePassword validates required fields', () async {
    final repository = _FakeAdminRepository();
    final viewModel = ProfileSecurityViewModel(repository: repository);

    final changed = await viewModel.changePassword(
      oldPassword: '',
      newPassword: '',
      confirmPassword: '',
    );

    expect(changed, isFalse);
    expect(viewModel.passwordError, '请填写原密码和新密码');
    expect(repository.changePasswordRequest, isNull);
  });

  test('changePassword rejects mismatched confirmation', () async {
    final repository = _FakeAdminRepository();
    final viewModel = ProfileSecurityViewModel(repository: repository);

    final changed = await viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'new-secret',
      confirmPassword: 'different',
    );

    expect(changed, isFalse);
    expect(viewModel.passwordError, '两次输入的新密码不一致');
    expect(repository.changePasswordRequest, isNull);
  });

  test('changePassword submits backend request', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      changePasswordResult: pending.future,
    );
    final viewModel = ProfileSecurityViewModel(repository: repository);

    final changeFuture = viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'new-secret',
      confirmPassword: 'new-secret',
    );

    expect(viewModel.isChangingPassword, isTrue);
    pending.complete(const Success<void>(null));
    final changed = await changeFuture;

    expect(changed, isTrue);
    expect(repository.changePasswordRequest?.oldPassword, 'old-secret');
    expect(repository.changePasswordRequest?.newPassword, 'new-secret');
    expect(viewModel.isChangingPassword, isFalse);
    expect(viewModel.passwordError, isNull);
    expect(viewModel.passwordMessage, '密码已更新');
  });

  test('changePassword ignores duplicate submission while pending', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      changePasswordResult: pending.future,
    );
    final viewModel = ProfileSecurityViewModel(repository: repository);

    final changeFuture = viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'new-secret',
      confirmPassword: 'new-secret',
    );

    expect(viewModel.isChangingPassword, isTrue);
    final duplicateFuture = viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'new-secret',
      confirmPassword: 'new-secret',
    );
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.changePasswordCallCount;

    pending.complete(const Success<void>(null));
    expect(await changeFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('changePassword exposes backend failure', () async {
    final repository = _FakeAdminRepository(
      changePasswordResult: Future.value(
        const FailureResult<void>(ValidationFailure(message: '原密码不正确')),
      ),
    );
    final viewModel = ProfileSecurityViewModel(repository: repository);

    final changed = await viewModel.changePassword(
      oldPassword: 'wrong',
      newPassword: 'new-secret',
      confirmPassword: 'new-secret',
    );

    expect(changed, isFalse);
    expect(viewModel.passwordError, '原密码不正确');
  });
}

final class _FakeAdminRepository implements AdminRepository {
  _FakeAdminRepository({this.changePasswordResult});

  final Future<Result<void>>? changePasswordResult;
  ChangeOwnPasswordRequest? changePasswordRequest;
  int changePasswordCallCount = 0;

  @override
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(<AdminUser>[]));
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) async {
    return const FailureResult<AdminUser>(UnknownFailure(message: 'not used'));
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) async {
    return const FailureResult<AdminUser>(UnknownFailure(message: 'not used'));
  }

  @override
  Future<Result<void>> deleteUser(int id) async {
    return const Success<void>(null);
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
  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(<AdminWarehouse>[]));
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

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    changePasswordCallCount += 1;
    changePasswordRequest = request;
    return changePasswordResult ?? Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
