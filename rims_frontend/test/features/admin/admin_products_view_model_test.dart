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
import 'package:rims_frontend/features/admin/presentation/view_models/admin_products_view_model.dart';

void main() {
  test('load exposes backend products', () async {
    final pending = Completer<Result<List<AdminProduct>>>();
    final repository = _FakeAdminRepository(listProductsResult: pending.future);
    final viewModel = AdminProductsViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    expect(repository.lastProductKeyword, '');

    pending.complete(const Success<List<AdminProduct>>([_water]));
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.products, [_water]);
  });

  test('load completes without notifying after disposal', () async {
    final pending = Completer<Result<List<AdminProduct>>>();
    final repository = _FakeAdminRepository(listProductsResult: pending.future);
    final viewModel = AdminProductsViewModel(repository: repository);

    final loadFuture = viewModel.load();
    viewModel.dispose();
    pending.complete(const Success<List<AdminProduct>>([_water]));

    await expectLater(loadFuture, completes);
  });

  test('reload failure keeps previously loaded products', () async {
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(const Success<List<AdminProduct>>([])),
      listProductsResults: [
        const Success<List<AdminProduct>>([_water]),
        const FailureResult<List<AdminProduct>>(
          NetworkFailure(message: '商品列表刷新失败'),
        ),
      ],
    );
    final viewModel = AdminProductsViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '商品列表刷新失败');
    expect(viewModel.products, [_water]);
    expect(viewModel.isEmpty, isFalse);
  });

  test('updateQuery reloads products with keyword', () async {
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(
        const Success<List<AdminProduct>>([_water]),
      ),
    );
    final viewModel = AdminProductsViewModel(repository: repository);

    await viewModel.updateQuery('SKU-WA');

    expect(viewModel.query, 'SKU-WA');
    expect(repository.lastProductKeyword, 'SKU-WA');
    expect(viewModel.products, [_water]);
  });

  test(
    'createProduct validates required fields before repository call',
    () async {
      final repository = _FakeAdminRepository(
        listProductsResult: Future.value(const Success<List<AdminProduct>>([])),
      );
      final viewModel = AdminProductsViewModel(repository: repository);

      final created = await viewModel.createProduct(
        const CreateAdminProductRequest(code: '', name: '', unit: ''),
      );

      expect(created, isFalse);
      expect(viewModel.formError, '请填写商品编码、名称和单位');
      expect(repository.createdProductRequest, isNull);
    },
  );

  test(
    'createProduct prepends created product after backend success',
    () async {
      final pending = Completer<Result<AdminProduct>>();
      final repository = _FakeAdminRepository(
        listProductsResult: Future.value(
          const Success<List<AdminProduct>>([_water]),
        ),
        createProductResult: pending.future,
      );
      final viewModel = AdminProductsViewModel(repository: repository);
      await viewModel.load();

      final createFuture = viewModel.createProduct(
        const CreateAdminProductRequest(
          code: 'SKU-TI',
          name: '纸巾',
          unit: '包',
          category: '日用品',
          retailPrice: 12.5,
          costPrice: 6,
        ),
      );

      expect(viewModel.isCreatingProduct, isTrue);
      pending.complete(const Success<AdminProduct>(_tissue));
      final created = await createFuture;

      expect(created, isTrue);
      expect(repository.createdProductRequest?.code, 'SKU-TI');
      expect(viewModel.isCreatingProduct, isFalse);
      expect(viewModel.formError, isNull);
      expect(viewModel.products, [_tissue, _water]);
    },
  );

  test(
    'createProduct publishes global refresh after backend success',
    () async {
      final eventBus = AppEventBus();
      addTearDown(eventBus.dispose);
      final repository = _FakeAdminRepository(
        listProductsResult: Future.value(
          const Success<List<AdminProduct>>([_water]),
        ),
      );
      final viewModel = AdminProductsViewModel(
        repository: repository,
        eventBus: eventBus,
      );
      await viewModel.load();
      final refreshEvent = eventBus.on<GlobalRefreshRequestedEvent>().first;

      final created = await viewModel.createProduct(
        const CreateAdminProductRequest(code: 'SKU-TI', name: '纸巾', unit: '包'),
      );

      expect(created, isTrue);
      await expectLater(refreshEvent, completes);
    },
  );

  test('createProduct ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminProduct>>();
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(
        const Success<List<AdminProduct>>([_water]),
      ),
      createProductResult: pending.future,
    );
    final viewModel = AdminProductsViewModel(repository: repository);
    await viewModel.load();

    const request = CreateAdminProductRequest(
      code: 'SKU-TI',
      name: '纸巾',
      unit: '包',
    );
    final createFuture = viewModel.createProduct(request);

    expect(viewModel.isCreatingProduct, isTrue);
    final duplicateFuture = viewModel.createProduct(request);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.createProductCallCount;

    pending.complete(const Success<AdminProduct>(_tissue));
    expect(await createFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test(
    'updateProduct replaces matching product after backend success',
    () async {
      final pending = Completer<Result<AdminProduct>>();
      final repository = _FakeAdminRepository(
        listProductsResult: Future.value(
          const Success<List<AdminProduct>>([_water]),
        ),
        updateProductResult: pending.future,
      );
      final viewModel = AdminProductsViewModel(repository: repository);
      await viewModel.load();

      final updateFuture = viewModel.updateProduct(
        const UpdateAdminProductRequest(
          id: 10,
          code: 'SKU-WA-600',
          name: '矿泉水 600ml',
          unit: '瓶',
          category: '饮料',
          retailPrice: 4,
          costPrice: 1.5,
          status: 0,
        ),
      );

      expect(viewModel.isUpdatingProduct, isTrue);
      pending.complete(const Success<AdminProduct>(_updatedWater));
      final updated = await updateFuture;

      expect(updated, isTrue);
      expect(repository.updatedProductRequest?.id, 10);
      expect(viewModel.isUpdatingProduct, isFalse);
      expect(viewModel.formError, isNull);
      expect(viewModel.products, [_updatedWater]);
    },
  );

  test('updateProduct ignores duplicate submission while pending', () async {
    final pending = Completer<Result<AdminProduct>>();
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(
        const Success<List<AdminProduct>>([_water]),
      ),
      updateProductResult: pending.future,
    );
    final viewModel = AdminProductsViewModel(repository: repository);
    await viewModel.load();

    const request = UpdateAdminProductRequest(
      id: 10,
      code: 'SKU-WA-600',
      name: '矿泉水 600ml',
      unit: '瓶',
    );
    final updateFuture = viewModel.updateProduct(request);

    expect(viewModel.isUpdatingProduct, isTrue);
    final duplicateFuture = viewModel.updateProduct(request);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.updateProductCallCount;

    pending.complete(const Success<AdminProduct>(_updatedWater));
    expect(await updateFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });

  test('deleteProduct exposes backend conflict and keeps product', () async {
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(
        const Success<List<AdminProduct>>([_water]),
      ),
      deleteProductResult: Future.value(
        const FailureResult<void>(ConflictFailure(message: '商品存在库存流水')),
      ),
    );
    final viewModel = AdminProductsViewModel(repository: repository);
    await viewModel.load();

    final deleted = await viewModel.deleteProduct(_water);

    expect(deleted, isFalse);
    expect(repository.deletedProductId, 10);
    expect(viewModel.productActionError, '商品存在库存流水');
    expect(viewModel.products, [_water]);
  });

  test(
    'deleteProduct removes matching product after backend success',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeAdminRepository(
        listProductsResult: Future.value(
          const Success<List<AdminProduct>>([_water, _tissue]),
        ),
        deleteProductResult: pending.future,
      );
      final viewModel = AdminProductsViewModel(repository: repository);
      await viewModel.load();

      final deleteFuture = viewModel.deleteProduct(_water);

      expect(viewModel.isDeletingProduct, isTrue);
      pending.complete(const Success<void>(null));
      final deleted = await deleteFuture;

      expect(deleted, isTrue);
      expect(repository.deletedProductId, 10);
      expect(viewModel.isDeletingProduct, isFalse);
      expect(viewModel.productActionError, isNull);
      expect(viewModel.products, [_tissue]);
    },
  );

  test('deleteProduct ignores duplicate submission while pending', () async {
    final pending = Completer<Result<void>>();
    final repository = _FakeAdminRepository(
      listProductsResult: Future.value(
        const Success<List<AdminProduct>>([_water, _tissue]),
      ),
      deleteProductResult: pending.future,
    );
    final viewModel = AdminProductsViewModel(repository: repository);
    await viewModel.load();

    final deleteFuture = viewModel.deleteProduct(_water);

    expect(viewModel.isDeletingProduct, isTrue);
    final duplicateFuture = viewModel.deleteProduct(_water);
    await Future<void>.delayed(Duration.zero);
    final callCountDuringPending = repository.deleteProductCallCount;

    pending.complete(const Success<void>(null));
    expect(await deleteFuture, isTrue);
    expect(await duplicateFuture, isFalse);
    expect(callCountDuringPending, 1);
  });
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
  _FakeAdminRepository({
    required this.listProductsResult,
    this.listProductsResults,
    this.createProductResult,
    this.updateProductResult,
    this.deleteProductResult,
  });

  final Future<Result<List<AdminProduct>>> listProductsResult;
  final List<Result<List<AdminProduct>>>? listProductsResults;
  final Future<Result<AdminProduct>>? createProductResult;
  final Future<Result<AdminProduct>>? updateProductResult;
  final Future<Result<void>>? deleteProductResult;
  String? lastProductKeyword;
  CreateAdminProductRequest? createdProductRequest;
  UpdateAdminProductRequest? updatedProductRequest;
  int? deletedProductId;
  int createProductCallCount = 0;
  int updateProductCallCount = 0;
  int deleteProductCallCount = 0;

  @override
  Future<Result<List<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) {
    lastProductKeyword = keyword;
    final queuedResults = listProductsResults;
    if (queuedResults != null && queuedResults.isNotEmpty) {
      return Future.value(queuedResults.removeAt(0));
    }
    return listProductsResult;
  }

  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) {
    createProductCallCount += 1;
    createdProductRequest = request;
    return createProductResult ?? Future.value(const Success(_tissue));
  }

  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) {
    updateProductCallCount += 1;
    updatedProductRequest = request;
    return updateProductResult ?? Future.value(const Success(_updatedWater));
  }

  @override
  Future<Result<void>> deleteProduct(int id) {
    deleteProductCallCount += 1;
    deletedProductId = id;
    return deleteProductResult ?? Future.value(const Success<void>(null));
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
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return Future.value(const Success<void>(null));
  }
}
