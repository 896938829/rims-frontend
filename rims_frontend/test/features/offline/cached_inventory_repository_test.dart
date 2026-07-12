import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_inventory_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';

void main() {
  var warehouseId = 11;
  final now = DateTime.utc(2026, 7, 13, 12);
  late _FakeInventoryRepository delegate;
  late CachedInventoryRepository repository;

  setUp(() {
    warehouseId = 11;
    delegate = _FakeInventoryRepository();
    repository = CachedInventoryRepository(
      delegate: delegate,
      store: MemoryOfflineStore(),
      accountIdReader: () => '7',
      warehouseIdReader: () => warehouseId,
      now: () => now,
    );
  });

  test('network page snapshot falls back with source and age', () async {
    delegate.inventoryResult = Success(_page([_item(1, quantity: 8)]));
    expect(
      _pageFrom(await repository.listInventory()).items.single.stockQuantity,
      8,
    );
    expect(repository.lastReadStatus?.source, InventoryDataSource.network);

    delegate.inventoryResult = const FailureResult(NetworkFailure());
    final cached = _pageFrom(await repository.listInventory());

    expect(cached.items.single.productId, 1);
    expect(cached.items.single.stockQuantity, 8);
    expect(repository.lastReadStatus?.source, InventoryDataSource.cache);
    expect(repository.lastReadStatus?.fetchedAt, now);
  });

  test('query key and warehouse scope are exact', () async {
    delegate.inventoryResult = Success(_page([_item(1)]));
    await repository.listInventory(keyword: 'milk', page: 1);
    delegate.inventoryResult = const FailureResult(NetworkFailure());

    expect(
      await repository.listInventory(keyword: 'water', page: 1),
      isA<FailureResult>(),
    );
    warehouseId = 12;
    expect(
      await repository.listInventory(keyword: 'milk', page: 1),
      isA<FailureResult>(),
    );
  });

  test('offline page stops pagination at the first cache gap', () async {
    delegate.inventoryResult = Success(
      PageData(items: [_item(1)], total: 40, page: 1, pageSize: 20),
    );
    await repository.listInventory(page: 1);
    delegate.inventoryResult = const FailureResult(NetworkFailure());

    final cached = _pageFrom(await repository.listInventory(page: 1));

    expect(cached.hasNextPage, isFalse);
    expect(cached.total, 20);
  });

  test('contiguous cached next page keeps offline pagination open', () async {
    delegate.inventoryResult = Success(
      PageData(items: [_item(1)], total: 40, page: 1, pageSize: 20),
    );
    await repository.listInventory(page: 1);
    delegate.inventoryResult = Success(
      PageData(items: [_item(2)], total: 40, page: 2, pageSize: 20),
    );
    await repository.listInventory(page: 2);
    delegate.inventoryResult = const FailureResult(NetworkFailure());

    expect(
      _pageFrom(await repository.listInventory(page: 1)).hasNextPage,
      isTrue,
    );
  });

  test('disabled product and refreshed quantity replace cached page', () async {
    delegate.inventoryResult = Success(
      _page([_item(1, quantity: 8, status: 0, statusLabel: '停用')]),
    );
    await repository.listInventory();
    delegate.inventoryResult = Success(
      _page([_item(1, quantity: 3, status: 0, statusLabel: '停用')]),
    );
    await repository.listInventory();
    delegate.inventoryResult = const FailureResult(NetworkFailure());

    final item = _pageFrom(await repository.listInventory()).items.single;
    expect(item.stockQuantity, 3);
    expect(item.status, 0);
    expect(item.statusLabel, '停用');
  });

  test(
    'barcode fallback preserves identity but never cached quantities',
    () async {
      delegate.barcodeResult = Success(_item(9, quantity: 22));
      await repository.findProductByBarcode(' 690001 ');
      delegate.barcodeResult = const FailureResult(NetworkFailure());

      final item = _itemFrom(await repository.findProductByBarcode('690001'));

      expect(item.productId, 9);
      expect(item.stockQuantity, 0);
      expect(item.availableQuantity, 0);
      expect(repository.lastReadStatus?.source, InventoryDataSource.cache);
    },
  );

  test('authorization and server failures never use inventory cache', () async {
    delegate.inventoryResult = Success(_page([_item(1)]));
    await repository.listInventory();
    for (final failure in <Failure>[
      const AuthorizationFailure(),
      const ServerFailure(),
    ]) {
      delegate.inventoryResult = FailureResult(failure);
      final result = await repository.listInventory();
      expect(result, isA<FailureResult<PageData<InventoryItem>>>());
      expect(
        (result as FailureResult<PageData<InventoryItem>>).failure,
        failure,
      );
    }
  });

  test(
    'inventory setting mutation always delegates and invalidates reads',
    () async {
      delegate.inventoryResult = Success(_page([_item(1)]));
      await repository.listInventory();
      delegate.settingsResult = Success(_item(1, quantity: 4));

      final result = await repository.updateInventorySettings(
        inventoryId: 101,
        alertThreshold: 2,
      );

      expect(result.isSuccess, isTrue);
      expect(delegate.settingsCalls, 1);
      delegate.inventoryResult = const FailureResult(NetworkFailure());
      expect(await repository.listInventory(), isA<FailureResult>());
    },
  );
}

PageData<InventoryItem> _page(List<InventoryItem> items) =>
    PageData(items: items, total: items.length, page: 1, pageSize: 20);

InventoryItem _item(
  int productId, {
  int quantity = 6,
  int status = 1,
  String statusLabel = '标准',
}) => InventoryItem(
  id: productId + 100,
  productId: productId,
  productName: 'Product $productId',
  sku: 'SKU-$productId',
  availableQuantity: quantity,
  stockQuantity: quantity,
  statusLabel: statusLabel,
  imageUrl: '',
  alertThreshold: 2,
  status: status,
  retailPrice: 12.5,
);

PageData<InventoryItem> _pageFrom(Result<PageData<InventoryItem>> result) =>
    result.when(
      success: (value) => value,
      failure: (failure) => throw TestFailure('Expected page: $failure'),
    );

InventoryItem _itemFrom(Result<InventoryItem> result) => result.when(
  success: (value) => value,
  failure: (failure) => throw TestFailure('Expected item: $failure'),
);

final class _FakeInventoryRepository implements InventoryRepository {
  Result<PageData<InventoryItem>> inventoryResult = const FailureResult(
    UnknownFailure(),
  );
  Result<PageData<InventoryItem>> alertsResult = const FailureResult(
    UnknownFailure(),
  );
  Result<InventoryItem> barcodeResult = const FailureResult(UnknownFailure());
  Result<InventoryItem> settingsResult = const FailureResult(UnknownFailure());
  Result<PageData<NonStandardInventoryItem>> nonStandardResult =
      const FailureResult(UnknownFailure());
  int settingsCalls = 0;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async => inventoryResult;

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async => alertsResult;

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async =>
      barcodeResult;

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    settingsCalls += 1;
    return settingsResult;
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async => nonStandardResult;
}
