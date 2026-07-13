import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/inventory/presentation/pages/inventory_page.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';
import 'package:rims_frontend/features/inventory/presentation/widgets/inventory_product_tile.dart';

void main() {
  testWidgets(
    'inventory thumbnail uses same-origin image and external fallback',
    (tester) async {
      const sameOrigin = InventoryItem(
        id: 70,
        productId: 10,
        productName: '有图商品',
        sku: 'SKU-IMAGE',
        availableQuantity: 1,
        stockQuantity: 1,
        statusLabel: '标准',
        imageUrl: '/uploads/product-10.jpg',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: InventoryProductTile(product: sameOrigin)),
        ),
      );
      expect(
        find.byKey(const Key('inventory-product-network-image')),
        findsOneWidget,
      );

      const external = InventoryItem(
        id: 71,
        productId: 11,
        productName: '外部图商品',
        sku: 'SKU-EXTERNAL',
        availableQuantity: 1,
        stockQuantity: 1,
        statusLabel: '标准',
        imageUrl: 'https://external.example/product.jpg',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: InventoryProductTile(product: external)),
        ),
      );
      expect(
        find.byKey(const Key('inventory-product-image-fallback')),
        findsOneWidget,
      );
    },
  );

  test(
    'InventoryViewModel ignores an async load completion after dispose',
    () async {
      final repository = _RetryInventoryRepository();
      final viewModel = InventoryViewModel(repository: repository);
      await viewModel.load();

      final loadFuture = viewModel.load();
      viewModel.dispose();
      repository.completeRetryInventory();

      await expectLater(loadFuture, completes);
      expect(viewModel.items, isEmpty);
      expect(viewModel.notifyListeners, throwsFlutterError);
    },
  );

  test('load sets loading then exposes backend inventory items', () async {
    final pending = Completer<Result<PageData<InventoryItem>>>();
    final repository = _FakeInventoryRepository(result: pending.future);
    final viewModel = InventoryViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    expect(repository.lastKeyword, '');

    pending.complete(Success(_inventoryPage([_standardItem])));
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.items, [_standardItem]);
    expect(viewModel.visibleItems, [_standardItem]);
  });

  test(
    'load exposes recent transactions for the selected inventory item',
    () async {
      final documentsRepository = _FakeDocumentsRepository(
        transactionResult: Success(
          _transactionPage([_standardTransaction, _otherTransaction]),
        ),
      );
      final viewModel = InventoryViewModel(
        repository: _FakeInventoryRepository(
          result: Future.value(Success(_inventoryPage([_standardItem]))),
        ),
        documentsRepository: documentsRepository,
      );

      await viewModel.load();
      viewModel.selectItem(_standardItem);

      expect(documentsRepository.listTransactionsCallCount, 1);
      expect(viewModel.transactionError, isNull);
      expect(viewModel.transactionsFor(_standardItem), [_standardTransaction]);
    },
  );

  test(
    'inventory history traverses transaction pages before filtering',
    () async {
      final documentsRepository = _FakeDocumentsRepository(
        transactionResults: [
          Success(
            _transactionPage(
              [_otherTransaction],
              total: 2,
              page: 1,
              pageSize: 1,
            ),
          ),
          Success(
            _transactionPage(
              [_standardTransaction],
              total: 2,
              page: 2,
              pageSize: 1,
            ),
          ),
        ],
      );
      final viewModel = InventoryViewModel(
        repository: _FakeInventoryRepository(
          result: Future.value(Success(_inventoryPage([_standardItem]))),
        ),
        documentsRepository: documentsRepository,
      );

      await viewModel.load();

      expect(documentsRepository.transactionPages, [1, 2]);
      expect(viewModel.transactionsFor(_standardItem), [_standardTransaction]);
    },
  );

  test('transaction failure does not clear loaded inventory items', () async {
    final viewModel = InventoryViewModel(
      repository: _FakeInventoryRepository(
        result: Future.value(Success(_inventoryPage([_standardItem]))),
      ),
      documentsRepository: _FakeDocumentsRepository(
        transactionResult: const FailureResult<PageData<TransactionRecord>>(
          NetworkFailure(message: '流水加载失败'),
        ),
      ),
    );

    await viewModel.load();

    expect(viewModel.items, [_standardItem]);
    expect(viewModel.transactions, isEmpty);
    expect(viewModel.transactionError, '流水加载失败');
  });

  test('updateQuery reloads inventory with keyword', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(Success(_inventoryPage([_lowStockItem]))),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.updateQuery('water');

    expect(viewModel.query, 'water');
    expect(repository.lastKeyword, 'water');
    expect(viewModel.items, [_lowStockItem]);
  });

  test('failure exposes user-facing error message', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        const FailureResult<PageData<InventoryItem>>(
          NetworkFailure(message: '网络不可用'),
        ),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '网络不可用');
    expect(viewModel.items, isEmpty);
  });

  test('reload failure keeps previously loaded inventory items', () async {
    final repository = _SequentialInventoryRepository(
      results: [
        Success(_inventoryPage([_standardItem])),
        FailureResult<PageData<InventoryItem>>(
          NetworkFailure(message: '库存服务短暂不可用'),
        ),
      ],
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '库存服务短暂不可用');
    expect(viewModel.items, [_standardItem]);
    expect(viewModel.visibleItems, [_standardItem]);
  });

  test('empty repository result exposes empty state', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(Success(_inventoryPage([]))),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.isEmpty, isTrue);
    expect(viewModel.visibleItems, isEmpty);
  });

  test('selected tab filters loaded items locally', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        Success(_inventoryPage([_standardItem, _nonStandardItem])),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    viewModel.selectTab('非标');

    expect(viewModel.visibleItems, [_nonStandardItem]);

    viewModel.selectTab('标准');

    expect(viewModel.visibleItems, [_standardItem]);
  });

  test('low stock tab filters warning inventory locally', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        Success(_inventoryPage([_standardItem, _lowStockItem])),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    viewModel.selectTab('低库存');

    expect(viewModel.visibleItems, [_lowStockItem]);
  });

  test('low stock tab excludes disabled inventory', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        Success(_inventoryPage([_standardItem, _lowStockItem, _disabledItem])),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    viewModel.selectTab('低库存');

    expect(viewModel.visibleItems, [_lowStockItem]);
  });

  test(
    'metrics describe loaded page coverage without partial aggregates',
    () async {
      final repository = _FakeInventoryRepository(
        result: Future.value(
          Success(
            _inventoryPage([_standardItem, _lowStockItem, _disabledItem]),
          ),
        ),
      );
      final viewModel = InventoryViewModel(repository: repository);

      await viewModel.load();

      expect(viewModel.metrics.map((metric) => metric.label), [
        '已加载',
        '总条目',
        '加载进度',
      ]);
      expect(viewModel.metrics.map((metric) => metric.value), [
        '3',
        '3',
        '3/3',
      ]);
    },
  );

  test('disabled tab filters inactive inventory locally', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        Success(_inventoryPage([_standardItem, _disabledItem])),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    viewModel.selectTab('停用');

    expect(viewModel.visibleItems, [_disabledItem]);
  });

  test('lookupBarcode selects backend product and trims input', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(Success(_inventoryPage([_standardItem]))),
      barcodeResult: const Success<InventoryItem>(_barcodeItem),
    );
    final viewModel = InventoryViewModel(repository: repository);

    final item = await viewModel.lookupBarcode(' 6901234567890 ');

    expect(repository.lastBarcode, '6901234567890');
    expect(item, _barcodeItem);
    expect(viewModel.selectedItem, _barcodeItem);
    expect(viewModel.barcodeLookupError, isNull);
    expect(viewModel.isLookingUpBarcode, isFalse);
  });

  test('admin updates selected inventory settings', () async {
    final updateCompleter = Completer<Result<InventoryItem>>();
    final repository = _FakeInventoryRepository(
      result: Future.value(Success(_inventoryPage([_standardItem]))),
      updateResult: updateCompleter.future,
    );
    final viewModel = InventoryViewModel(
      repository: repository,
      canManageInventorySettings: true,
    );
    await viewModel.load();
    viewModel.selectItem(_standardItem);

    final saveFuture = viewModel.updateSelectedItemSettings(
      alertThreshold: 12,
      status: 1,
    );

    expect(viewModel.isSavingSettings, isTrue);
    updateCompleter.complete(
      const Success<InventoryItem>(_updatedStandardItem),
    );
    final saved = await saveFuture;

    expect(saved, isTrue);
    expect(repository.updatedInventoryId, 1);
    expect(repository.updatedAlertThreshold, 12);
    expect(repository.updatedStatus, 1);
    expect(viewModel.isSavingSettings, isFalse);
    expect(viewModel.settingsError, isNull);
    expect(viewModel.selectedItem, _updatedStandardItem);
    expect(viewModel.items, [_updatedStandardItem]);
  });

  test('ordinary user cannot update inventory settings', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(Success(_inventoryPage([_standardItem]))),
    );
    final viewModel = InventoryViewModel(repository: repository);

    viewModel.selectItem(_standardItem);
    final saved = await viewModel.updateSelectedItemSettings(
      alertThreshold: 12,
      status: 1,
    );

    expect(saved, isFalse);
    expect(repository.updatedInventoryId, isNull);
    expect(viewModel.settingsError, '无权限调整库存设置');
  });

  testWidgets('InventoryPage opens detail sheet when product is tapped', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _FakeInventoryRepository(
        result: Future.value(Success(_inventoryPage([_standardItem]))),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('inventory-item-1')), findsOneWidget);
    expect(find.byKey(const Key('inventory-item-code-1')), findsOneWidget);

    await tester.tap(find.text('矿泉水 550ml'));
    await tester.pumpAndSettle();

    expect(find.text('库存详情'), findsOneWidget);
    expect(find.text('SKU-WA-550'), findsWidgets);
    expect(find.text('可用库存'), findsOneWidget);
    expect(find.text('128'), findsWidgets);
  });

  testWidgets('InventoryPage detail shows recent stock transactions', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _FakeInventoryRepository(
        result: Future.value(Success(_inventoryPage([_standardItem]))),
      ),
      documentsRepository: _FakeDocumentsRepository(
        transactionResult: Success(_transactionPage([_standardTransaction])),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    await tester.tap(find.text('矿泉水 550ml'));
    await tester.pumpAndSettle();

    expect(find.text('最近库存流水'), findsOneWidget);
    expect(find.text('销售单 · XS20260627001'), findsOneWidget);
    expect(find.text('150 -> 128'), findsOneWidget);
    expect(find.text('出库'), findsOneWidget);
  });

  testWidgets('InventoryPage retries loading after an error', (tester) async {
    final repository = _RetryInventoryRepository();
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );
    await tester.pump();

    expect(find.text('库存服务不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(find.text('正在加载库存...'), findsOneWidget);

    repository.completeRetryInventory();
    await tester.pumpAndSettle();

    expect(repository.listInventoryCallCount, 2);
    expect(find.text('库存服务不可用'), findsNothing);
    expect(find.text('矿泉水 550ml'), findsOneWidget);
  });

  testWidgets('InventoryPage shows settings form for admin detail', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _FakeInventoryRepository(
        result: Future.value(Success(_inventoryPage([_standardItem]))),
      ),
      canManageInventorySettings: true,
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    await tester.tap(find.text('矿泉水 550ml'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inventory-alert-threshold-field')), findsOne);
    expect(find.byKey(const Key('inventory-status-field')), findsOneWidget);
    expect(find.byKey(const Key('inventory-save-settings-button')), findsOne);
  });

  testWidgets('InventoryPage hides settings form for ordinary user detail', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _FakeInventoryRepository(
        result: Future.value(Success(_inventoryPage([_standardItem]))),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    await tester.tap(find.text('矿泉水 550ml'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('inventory-alert-threshold-field')),
      findsNothing,
    );
    expect(find.byKey(const Key('inventory-status-field')), findsNothing);
    expect(
      find.byKey(const Key('inventory-save-settings-button')),
      findsNothing,
    );
  });

  test('initial page replaces rows and exposes server coverage', () async {
    final repository = _QueuedInventoryRepository([
      Future.value(Success(_inventoryPage([_standardItem], total: 45))),
    ]);
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.items, [_standardItem]);
    expect(viewModel.loadedCount, 1);
    expect(viewModel.total, 45);
    expect(viewModel.hasMore, isTrue);
    expect(repository.requestedPages, [1]);
  });

  test('loadMore appends in order and replaces duplicate IDs', () async {
    const updatedStandard = InventoryItem(
      id: 1,
      productId: 10,
      productName: '矿泉水 550ml',
      sku: 'SKU-WA-550',
      availableQuantity: 99,
      stockQuantity: 120,
      statusLabel: '标准',
      imageUrl: '',
    );
    final repository = _QueuedInventoryRepository([
      Future.value(Success(_inventoryPage([_standardItem], total: 45))),
      Future.value(
        Success(
          _inventoryPage([updatedStandard, _lowStockItem], total: 45, page: 2),
        ),
      ),
    ]);
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    await viewModel.loadMore();

    expect(viewModel.items, [updatedStandard, _lowStockItem]);
    expect(repository.requestedPages, [1, 2]);
  });

  test(
    'load-more failure preserves rows and retry requests same page',
    () async {
      final repository = _QueuedInventoryRepository([
        Future.value(Success(_inventoryPage([_standardItem], total: 45))),
        Future.value(
          const FailureResult<PageData<InventoryItem>>(
            NetworkFailure(message: '下一页暂时不可用'),
          ),
        ),
        Future.value(
          Success(_inventoryPage([_lowStockItem], total: 45, page: 2)),
        ),
      ]);
      final viewModel = InventoryViewModel(repository: repository);

      await viewModel.load();
      await viewModel.loadMore();

      expect(viewModel.items, [_standardItem]);
      expect(viewModel.errorMessage, isNull);
      expect(viewModel.loadMoreFailure?.message, '下一页暂时不可用');

      await viewModel.retryLoadMore();

      expect(repository.requestedPages, [1, 2, 2]);
      expect(viewModel.items, [_standardItem, _lowStockItem]);
      expect(viewModel.loadMoreFailure, isNull);
    },
  );

  test('concurrent loadMore calls issue only one request', () async {
    final pendingPage = Completer<Result<PageData<InventoryItem>>>();
    final repository = _QueuedInventoryRepository([
      Future.value(Success(_inventoryPage([_standardItem], total: 45))),
      pendingPage.future,
    ]);
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();

    final first = viewModel.loadMore();
    final second = viewModel.loadMore();

    expect(viewModel.isLoadingMore, isTrue);
    expect(repository.requestedPages, [1, 2]);
    pendingPage.complete(
      Success(_inventoryPage([_lowStockItem], total: 45, page: 2)),
    );
    await Future.wait([first, second]);
  });

  test('query reset ignores an obsolete in-flight next page', () async {
    final stalePage = Completer<Result<PageData<InventoryItem>>>();
    final repository = _QueuedInventoryRepository([
      Future.value(Success(_inventoryPage([_standardItem], total: 45))),
      stalePage.future,
      Future.value(Success(_inventoryPage([_lowStockItem]))),
    ]);
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();

    final oldLoadMore = viewModel.loadMore();
    await viewModel.updateQuery('low');
    stalePage.complete(
      Success(_inventoryPage([_disabledItem], total: 45, page: 2)),
    );
    await oldLoadMore;

    expect(repository.requestedPages, [1, 2, 1]);
    expect(repository.requestedKeywords, ['', '', 'low']);
    expect(viewModel.items, [_lowStockItem]);
  });

  test('an empty next page ends pagination despite stale total', () async {
    final repository = _QueuedInventoryRepository([
      Future.value(Success(_inventoryPage([_standardItem], total: 45))),
      Future.value(Success(_inventoryPage([], total: 45, page: 2))),
    ]);
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    await viewModel.loadMore();

    expect(viewModel.items, [_standardItem]);
    expect(viewModel.hasMore, isFalse);
  });

  testWidgets('cached inventory renders explicit source and update time', (
    tester,
  ) async {
    final repository = _MetadataInventoryRepository(
      status: InventoryReadStatus(
        source: InventoryDataSource.cache,
        fetchedAt: DateTime(2026, 7, 13, 12),
        expiresAt: DateTime(2026, 7, 14, 12),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    expect(viewModel.isShowingCachedData, isTrue);
    expect(find.text('离线缓存 · 更新于 2026-07-13 12:00'), findsOneWidget);
  });

  test(
    'cached quantities cannot authorize inventory setting mutation',
    () async {
      final repository = _MetadataInventoryRepository(
        status: InventoryReadStatus(
          source: InventoryDataSource.cache,
          fetchedAt: DateTime(2026, 7, 13, 12),
          expiresAt: DateTime(2026, 7, 14, 12),
        ),
      );
      final viewModel = InventoryViewModel(
        repository: repository,
        canManageInventorySettings: true,
      );
      await viewModel.load();
      viewModel.selectItem(_standardItem);

      expect(
        await viewModel.updateSelectedItemSettings(alertThreshold: 3),
        isFalse,
      );
      expect(repository.settingsCalls, 0);
      expect(viewModel.settingsError, '离线缓存不可用于库存设置变更');
    },
  );
}

const _standardItem = InventoryItem(
  id: 1,
  productId: 10,
  productName: '矿泉水 550ml',
  sku: 'SKU-WA-550',
  availableQuantity: 128,
  stockQuantity: 150,
  statusLabel: '标准',
  imageUrl: '',
);

const _updatedStandardItem = InventoryItem(
  id: 1,
  productId: 10,
  productName: '矿泉水 550ml',
  sku: 'SKU-WA-550',
  availableQuantity: 128,
  stockQuantity: 150,
  statusLabel: '标准',
  imageUrl: '',
  alertThreshold: 12,
  status: 1,
);

const _lowStockItem = InventoryItem(
  id: 2,
  productId: 20,
  productName: '低库存商品',
  sku: 'SKU-LOW',
  availableQuantity: 2,
  stockQuantity: 3,
  statusLabel: '低库存',
  imageUrl: '',
);

const _disabledItem = InventoryItem(
  id: 4,
  productId: 40,
  productName: '停用商品',
  sku: 'SKU-DISABLED',
  availableQuantity: 0,
  stockQuantity: 0,
  statusLabel: '停用',
  imageUrl: '',
  status: 0,
);

const _barcodeItem = InventoryItem(
  id: 0,
  productId: 10,
  productName: '矿泉水 550ml',
  sku: 'SKU-WA-550',
  availableQuantity: 0,
  stockQuantity: 0,
  statusLabel: '标准',
  imageUrl: '',
);

const _nonStandardItem = InventoryItem(
  id: 3,
  productId: 30,
  productName: '非标样品',
  sku: 'SKU-NS',
  availableQuantity: 8,
  stockQuantity: 8,
  statusLabel: '非标',
  imageUrl: '',
);

const _standardTransaction = TransactionRecord(
  id: 21,
  warehouseId: 1,
  productId: 10,
  docId: 7,
  docNo: 'XS20260627001',
  docType: 2,
  docTypeName: '销售单',
  direction: -1,
  quantity: 22,
  beforeQty: 150,
  afterQty: 128,
  operatorId: 5,
  operatedAt: '2026-06-27T10:30:00Z',
  createdAt: '2026-06-27T10:30:00Z',
);

const _otherTransaction = TransactionRecord(
  id: 22,
  warehouseId: 1,
  productId: 20,
  docId: 8,
  docNo: 'RK20260627001',
  docType: 1,
  docTypeName: '采购单',
  direction: 1,
  quantity: 3,
  beforeQty: 0,
  afterQty: 3,
  operatorId: 5,
  operatedAt: '2026-06-27T11:30:00Z',
  createdAt: '2026-06-27T11:30:00Z',
);

PageData<InventoryItem> _inventoryPage(
  List<InventoryItem> items, {
  int? total,
  int page = 1,
}) {
  return PageData<InventoryItem>(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: 20,
  );
}

PageData<NonStandardInventoryItem> _nonStandardInventoryPage(
  List<NonStandardInventoryItem> items,
) {
  return PageData<NonStandardInventoryItem>(
    items: items,
    total: items.length,
    page: 1,
    pageSize: 20,
  );
}

PageData<TransactionRecord> _transactionPage(
  List<TransactionRecord> items, {
  int? total,
  int page = 1,
  int pageSize = 10,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: pageSize,
  );
}

final class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository({
    required this.result,
    this.barcodeResult = const Success<InventoryItem>(_barcodeItem),
    this.updateResult,
  });

  final Future<Result<PageData<InventoryItem>>> result;
  final Result<InventoryItem> barcodeResult;
  final Future<Result<InventoryItem>>? updateResult;
  String? lastKeyword;
  String? lastBarcode;
  int? updatedInventoryId;
  int? updatedAlertThreshold;
  int? updatedStatus;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) {
    lastKeyword = keyword;
    return result;
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_inventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    lastBarcode = barcode;
    return barcodeResult;
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    updatedInventoryId = inventoryId;
    updatedAlertThreshold = alertThreshold;
    updatedStatus = status;
    return updateResult ?? const Success<InventoryItem>(_updatedStandardItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success(_nonStandardInventoryPage([]));
  }
}

final class _SequentialInventoryRepository implements InventoryRepository {
  _SequentialInventoryRepository({required this.results});

  final List<Result<PageData<InventoryItem>>> results;
  int listInventoryCallCount = 0;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    final callIndex = listInventoryCallCount;
    listInventoryCallCount += 1;
    if (callIndex < results.length) {
      return results[callIndex];
    }

    return results.last;
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_inventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_barcodeItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_updatedStandardItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success(_nonStandardInventoryPage([]));
  }
}

final class _FakeDocumentsRepository implements DocumentsRepository {
  _FakeDocumentsRepository({
    Result<PageData<TransactionRecord>>? transactionResult,
    List<Result<PageData<TransactionRecord>>>? transactionResults,
  }) : transactionResults =
           transactionResults ??
           [transactionResult ?? Success(_transactionPage([]))];

  final List<Result<PageData<TransactionRecord>>> transactionResults;
  int listTransactionsCallCount = 0;
  final List<int> transactionPages = [];

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    return Success(
      PageData(
        items: const <DocumentRecord>[],
        total: 0,
        page: 1,
        pageSize: 10,
      ),
    );
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    transactionPages.add(page);
    final index = listTransactionsCallCount;
    listTransactionsCallCount += 1;
    return transactionResults[index.clamp(0, transactionResults.length - 1)];
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(
      DocumentRecord(
        id: 1,
        docType: 1,
        title: '采购单',
        number: 'RK-1',
        status: '草稿',
      ),
    );
  }

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }
}

final class _RetryInventoryRepository implements InventoryRepository {
  int listInventoryCallCount = 0;
  Completer<List<InventoryItem>>? _retryInventoryCompleter;

  void completeRetryInventory() {
    _retryInventoryCompleter?.complete([_standardItem]);
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    listInventoryCallCount += 1;
    if (listInventoryCallCount == 1) {
      return const FailureResult<PageData<InventoryItem>>(
        NetworkFailure(message: '库存服务不可用'),
      );
    }

    _retryInventoryCompleter = Completer<List<InventoryItem>>();
    return Success(_inventoryPage(await _retryInventoryCompleter!.future));
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_inventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_barcodeItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_updatedStandardItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success(_nonStandardInventoryPage([]));
  }
}

final class _QueuedInventoryRepository implements InventoryRepository {
  _QueuedInventoryRepository(this._results);

  final List<Future<Result<PageData<InventoryItem>>>> _results;
  final List<int> requestedPages = [];
  final List<String> requestedKeywords = [];
  int _resultIndex = 0;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) {
    requestedPages.add(page);
    requestedKeywords.add(keyword);
    final index = _resultIndex;
    _resultIndex += 1;
    return _results[index];
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_inventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success(_barcodeItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success(_nonStandardInventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success(_updatedStandardItem);
  }
}

final class _MetadataInventoryRepository
    implements InventoryRepository, InventoryReadMetadata {
  _MetadataInventoryRepository({required this.status});

  final InventoryReadStatus status;
  int settingsCalls = 0;

  @override
  InventoryReadStatus? get lastReadStatus => status;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async => Success(_inventoryPage([_standardItem]));

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async => Success(_inventoryPage([_standardItem]));

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async =>
      const Success(_barcodeItem);

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async => Success(_nonStandardInventoryPage([]));

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    settingsCalls += 1;
    return const Success(_updatedStandardItem);
  }
}
