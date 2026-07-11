import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/repositories/admin_repository.dart';
import 'package:rims_frontend/features/admin/presentation/widgets/admin_products_panel.dart';

import 'admin_page_test_support.dart';

void main() {
  testWidgets('AdminProductsPanel loads products and creates product', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminProductsPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('profile-admin-products-panel')),
      findsOneWidget,
    );
    expect(find.text('矿泉水 550ml'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin-create-product-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-create-product-code-field')),
      'SKU-TI',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-name-field')),
      '纸巾',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-unit-field')),
      '包',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-category-field')),
      '日用品',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-retail-price-field')),
      '12.5',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-cost-price-field')),
      '6',
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-create-product-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.createdProductRequest?.code, 'SKU-TI');
    expect(repository.createdProductRequest?.unit, '包');
    expect(repository.createdProductRequest?.retailPrice, 12.5);
    expect(find.text('纸巾'), findsOneWidget);
  });

  testWidgets('AdminProductsPanel rejects malformed create price', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminProductsPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-create-product-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-create-product-code-field')),
      'SKU-TI',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-name-field')),
      '纸巾',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-unit-field')),
      '包',
    );
    await tester.enterText(
      find.byKey(const Key('admin-create-product-retail-price-field')),
      'abc',
    );
    await tester.tap(
      find.byKey(const Key('admin-submit-create-product-button')),
    );
    await tester.pumpAndSettle();

    expect(repository.createdProductRequest, isNull);
    expect(find.text('价格只能填写数字'), findsOneWidget);
  });

  testWidgets('AdminProductsPanel updates selected product', (tester) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminProductsPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-edit-product-10-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-code-field')),
      'SKU-WA-600',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-name-field')),
      '矿泉水 600ml',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-unit-field')),
      '瓶',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-retail-price-field')),
      '4',
    );
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-cost-price-field')),
      '1.5',
    );
    await tester.ensureVisible(
      find.byKey(const Key('admin-edit-product-status-switch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin-edit-product-status-switch')));
    await tester.tap(find.byKey(const Key('admin-submit-edit-product-button')));
    await tester.pumpAndSettle();

    expect(repository.updatedProductRequest?.id, 10);
    expect(repository.updatedProductRequest?.code, 'SKU-WA-600');
    expect(repository.updatedProductRequest?.status, 0);
    expect(find.text('矿泉水 600ml'), findsOneWidget);
  });

  testWidgets('AdminProductsPanel rejects malformed edit price', (
    tester,
  ) async {
    final repository = _FakeAdminRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminProductsPanel(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-edit-product-10-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin-edit-product-cost-price-field')),
      'bad',
    );
    await tester.tap(find.byKey(const Key('admin-submit-edit-product-button')));
    await tester.pumpAndSettle();

    expect(repository.updatedProductRequest, isNull);
    expect(find.text('价格只能填写数字'), findsOneWidget);
  });

  testWidgets(
    'AdminProductsPanel deletes selected product after confirmation',
    (tester) async {
      final repository = _FakeAdminRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminProductsPanel(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-delete-product-10-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin-confirm-delete-product-button')),
      );
      await tester.pumpAndSettle();

      expect(repository.deletedProductId, 10);
      expect(find.text('矿泉水 550ml'), findsNothing);
    },
  );
}

const _water = AdminProduct(
  id: 10,
  code: 'SKU-WA-550',
  name: '矿泉水 550ml',
  unit: '瓶',
  category: '饮料',
  spec: '550ml',
  barcode: '6901234567890',
  retailPrice: 3.5,
  costPrice: 1.2,
  imageUrl: '',
  status: 1,
);

const _tissue = AdminProduct(
  id: 11,
  code: 'SKU-TI',
  name: '纸巾',
  unit: '包',
  category: '日用品',
  spec: '',
  barcode: '',
  retailPrice: 12.5,
  costPrice: 6,
  imageUrl: '',
  status: 1,
);

const _updatedWater = AdminProduct(
  id: 10,
  code: 'SKU-WA-600',
  name: '矿泉水 600ml',
  unit: '瓶',
  category: '饮料',
  spec: '600ml',
  barcode: '6901234567890',
  retailPrice: 4,
  costPrice: 1.5,
  imageUrl: '',
  status: 0,
);

final class _FakeAdminRepository implements AdminRepository {
  final List<AdminProduct> _products = [_water];
  CreateAdminProductRequest? createdProductRequest;
  UpdateAdminProductRequest? updatedProductRequest;
  int? deletedProductId;

  @override
  Future<Result<PageData<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    return Success(adminPage(_products));
  }

  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) async {
    createdProductRequest = request;
    _products.insert(0, _tissue);
    return const Success<AdminProduct>(_tissue);
  }

  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) async {
    updatedProductRequest = request;
    _products[_products.indexWhere(
          (product) => product.id == _updatedWater.id,
        )] =
        _updatedWater;
    return const Success<AdminProduct>(_updatedWater);
  }

  @override
  Future<Result<void>> deleteProduct(int id) async {
    deletedProductId = id;
    _products.removeWhere((product) => product.id == id);
    return const Success<void>(null);
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
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
