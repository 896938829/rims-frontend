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
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Different-pass-2026',
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
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Secure-pass-2026',
    );

    expect(viewModel.isChangingPassword, isTrue);
    pending.complete(const Success<void>(null));
    final changed = await changeFuture;

    expect(changed, isTrue);
    expect(repository.changePasswordRequest?.oldPassword, 'old-secret');
    expect(repository.changePasswordRequest?.newPassword, 'Secure-pass-2026');
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
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Secure-pass-2026',
    );

    expect(viewModel.isChangingPassword, isTrue);
    final duplicateFuture = viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Secure-pass-2026',
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
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Secure-pass-2026',
    );

    expect(changed, isFalse);
    expect(viewModel.passwordError, '原密码不正确');
  });

  test('changePassword preserves password whitespace exactly', () async {
    final repository = _FakeAdminRepository();
    final viewModel = ProfileSecurityViewModel(repository: repository);

    expect(
      await viewModel.changePassword(
        oldPassword: ' old-secret ',
        newPassword: ' 123456789012 ',
        confirmPassword: ' 123456789012 ',
      ),
      isTrue,
    );
    expect(repository.changePasswordRequest?.oldPassword, ' old-secret ');
    expect(repository.changePasswordRequest?.newPassword, ' 123456789012 ');
  });

  test('changePassword enforces only new password 12 to 128 bounds', () async {
    final repository = _FakeAdminRepository();
    final viewModel = ProfileSecurityViewModel(repository: repository);

    expect(
      await viewModel.changePassword(
        oldPassword: ' ',
        newPassword: '12345678901',
        confirmPassword: '12345678901',
      ),
      isFalse,
    );
    expect(viewModel.passwordError, '新密码至少需要12个字符');
    expect(
      await viewModel.changePassword(
        oldPassword: ' ',
        newPassword: List.filled(129, 'x').join(),
        confirmPassword: List.filled(129, 'x').join(),
      ),
      isFalse,
    );
    expect(viewModel.passwordError, '新密码最多允许128个字符');
    expect(repository.changePasswordCallCount, 0);
  });

  test(
    'changePassword contains repository exceptions and restores terminal state',
    () async {
      final repository = _FakeAdminRepository(throwOnChangePassword: true);
      final viewModel = ProfileSecurityViewModel(repository: repository);

      expect(
        await viewModel.changePassword(
          oldPassword: 'old-secret',
          newPassword: 'Secure-pass-2026',
          confirmPassword: 'Secure-pass-2026',
        ),
        isFalse,
      );
      expect(viewModel.isChangingPassword, isFalse);
      expect(viewModel.passwordError, '密码更新失败，请重试');
    },
  );

  test('dispose ignores a delayed password change completion', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      changePasswordResult: pending.future,
    );
    final viewModel = ProfileSecurityViewModel(repository: repository);
    final changing = viewModel.changePassword(
      oldPassword: 'old-secret',
      newPassword: 'Secure-pass-2026',
      confirmPassword: 'Secure-pass-2026',
    );
    viewModel.dispose();
    pending.complete(const Success<void>(null));
    expect(await changing, isFalse);
  });
}

final class _FakeAdminRepository implements AdminRepository {
  _FakeAdminRepository({
    this.changePasswordResult,
    this.throwOnChangePassword = false,
  });

  final Future<Result<void>>? changePasswordResult;
  final bool throwOnChangePassword;
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
  Future<Result<PageData<AdminUser>>> listWarehouseUsers(
    int warehouseId, {
    int page = 1,
  }) async {
    return Success(adminPage(<AdminUser>[], page: page));
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
    if (throwOnChangePassword) {
      throw StateError('injected password change failure');
    }
    return changePasswordResult ?? Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
