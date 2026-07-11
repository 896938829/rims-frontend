import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/view_models/admin_products_view_model.dart';
import 'package:rims_frontend/features/admin/presentation/view_models/admin_users_view_model.dart';
import 'package:rims_frontend/features/admin/presentation/view_models/admin_warehouses_view_model.dart';

import 'admin_page_test_support.dart';

void main() {
  test('users append, retry the same page, dedupe, and reset query', () async {
    final repository = _PagingAdminRepository(
      userPages: [
        Success(adminPage([_user], total: 45)),
        const FailureResult(NetworkFailure(message: 'users next failed')),
        Success(adminPage([_updatedUser, _userTwo], total: 2, page: 2)),
        Success(adminPage([_userTwo])),
      ],
    );
    final viewModel = AdminUsersViewModel(repository: repository);
    await viewModel.load();
    await viewModel.loadMore();
    expect(viewModel.users, [_user]);
    expect(viewModel.loadMoreFailure?.message, 'users next failed');
    await viewModel.retryLoadMore();
    expect(viewModel.users, [_updatedUser, _userTwo]);
    expect(repository.userPagesRequested, [1, 2, 2]);
    await viewModel.updateQuery('two');
    expect(repository.userPagesRequested, [1, 2, 2, 1]);
    expect(repository.userKeywords.last, 'two');
    expect(viewModel.users, [_userTwo]);
  });

  test('products append and stop on the final page', () async {
    final repository = _PagingAdminRepository(
      productPages: [
        Success(adminPage([_product], total: 21)),
        Success(adminPage([_productTwo], total: 2, page: 2)),
      ],
    );
    final viewModel = AdminProductsViewModel(repository: repository);
    await viewModel.load();
    await viewModel.loadMore();
    expect(viewModel.products, [_product, _productTwo]);
    expect(viewModel.hasMore, isFalse);
    expect(repository.productPagesRequested, [1, 2]);
  });

  test('warehouses append and stop on the final page', () async {
    final repository = _PagingAdminRepository(
      warehousePages: [
        Success(adminPage([_warehouse], total: 21)),
        Success(adminPage([_warehouseTwo], total: 2, page: 2)),
      ],
    );
    final viewModel = AdminWarehousesViewModel(repository: repository);
    await viewModel.load();
    await viewModel.loadMore();
    expect(viewModel.warehouses, [_warehouse, _warehouseTwo]);
    expect(viewModel.hasMore, isFalse);
    expect(repository.warehousePagesRequested, [1, 2]);
  });

  test('loaded mutations refresh page one for all admin collections', () async {
    final repository = _PagingAdminRepository(
      userPages: [
        Success(adminPage([_user])),
        Success(adminPage([_userTwo])),
      ],
      productPages: [
        Success(adminPage([_product])),
        Success(adminPage([_productTwo])),
      ],
      warehousePages: [
        Success(adminPage([_warehouse])),
        Success(adminPage([_warehouseTwo])),
      ],
    );
    final users = AdminUsersViewModel(repository: repository);
    final products = AdminProductsViewModel(repository: repository);
    final warehouses = AdminWarehousesViewModel(repository: repository);
    await users.load();
    await products.load();
    await warehouses.load();

    await users.createUser(
      const CreateAdminUserRequest(username: 'two', password: 'pw', roleId: 2),
    );
    await products.createProduct(
      const CreateAdminProductRequest(code: 'P2', name: 'two', unit: '件'),
    );
    await warehouses.createWarehouse(
      const CreateAdminWarehouseRequest(code: 'W2', name: 'two'),
    );

    expect(repository.userPagesRequested, [1, 1]);
    expect(repository.productPagesRequested, [1, 1]);
    expect(repository.warehousePagesRequested, [1, 1]);
    expect(users.users, [_userTwo]);
    expect(products.products, [_productTwo]);
    expect(warehouses.warehouses, [_warehouseTwo]);
  });
}

const _user = AdminUser(
  id: 1,
  username: 'one',
  realName: '',
  phone: '',
  email: '',
  roleId: 2,
  roleCode: 'user',
  roleName: '用户',
  status: 1,
);
const _updatedUser = AdminUser(
  id: 1,
  username: 'one',
  realName: 'updated',
  phone: '',
  email: '',
  roleId: 2,
  roleCode: 'user',
  roleName: '用户',
  status: 1,
);
const _userTwo = AdminUser(
  id: 2,
  username: 'two',
  realName: '',
  phone: '',
  email: '',
  roleId: 2,
  roleCode: 'user',
  roleName: '用户',
  status: 1,
);
const _product = AdminProduct(
  id: 1,
  code: 'P1',
  name: 'one',
  unit: '件',
  category: '',
  spec: '',
  barcode: '',
  retailPrice: null,
  costPrice: null,
  imageUrl: '',
  status: 1,
);
const _productTwo = AdminProduct(
  id: 2,
  code: 'P2',
  name: 'two',
  unit: '件',
  category: '',
  spec: '',
  barcode: '',
  retailPrice: null,
  costPrice: null,
  imageUrl: '',
  status: 1,
);
const _warehouse = AdminWarehouse(
  id: 1,
  code: 'W1',
  name: 'one',
  status: 1,
  address: '',
  contactPerson: '',
  contactPhone: '',
);
const _warehouseTwo = AdminWarehouse(
  id: 2,
  code: 'W2',
  name: 'two',
  status: 1,
  address: '',
  contactPerson: '',
  contactPhone: '',
);

final class _PagingAdminRepository implements AdminRepository {
  _PagingAdminRepository({
    this.userPages = const [],
    this.productPages = const [],
    this.warehousePages = const [],
  });
  final List<Result<PageData<AdminUser>>> userPages;
  final List<Result<PageData<AdminProduct>>> productPages;
  final List<Result<PageData<AdminWarehouse>>> warehousePages;
  final List<int> userPagesRequested = [];
  final List<int> productPagesRequested = [];
  final List<int> warehousePagesRequested = [];
  final List<String> userKeywords = [];
  int _userIndex = 0, _productIndex = 0, _warehouseIndex = 0;

  @override
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    userPagesRequested.add(page);
    userKeywords.add(keyword);
    return userPages[_userIndex++];
  }

  @override
  Future<Result<PageData<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    productPagesRequested.add(page);
    return productPages[_productIndex++];
  }

  @override
  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    warehousePagesRequested.add(page);
    return warehousePages[_warehouseIndex++];
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) async =>
      const Success(_userTwo);
  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) async => const Success(_productTwo);
  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async => const Success(_warehouseTwo);
  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) async =>
      const Success(_updatedUser);
  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) async => const Success(_product);
  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async => const Success(_warehouse);
  @override
  Future<Result<void>> deleteUser(int id) async => const Success(null);
  @override
  Future<Result<void>> deleteProduct(int id) async => const Success(null);
  @override
  Future<Result<void>> deleteWarehouse(int id) async => const Success(null);
  @override
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) async =>
      const Success([]);
  @override
  Future<Result<void>> bindWarehouseUsers(
    BindWarehouseUsersRequest request,
  ) async => const Success(null);
  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) async => const Success(null);
  @override
  Future<Result<List<AdminRole>>> listRoles() async => const Success([]);
  @override
  Future<Result<List<AdminPermission>>> listPermissions() async =>
      const Success([]);
  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) async => const Success(null);
  @override
  Future<Result<void>> changeOwnPassword(
    ChangeOwnPasswordRequest request,
  ) async => const Success(null);
  @override
  Future<Result<void>> resetUserPassword(
    ResetUserPasswordRequest request,
  ) async => const Success(null);
}
