import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/widgets/rims_status_chip.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/home/presentation/pages/home_page.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';
import 'package:rims_frontend/features/home/presentation/widgets/recent_document_tile.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/reports/domain/entities/report_data.dart';
import 'package:rims_frontend/features/reports/domain/repositories/reports_repository.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  test('HomeViewModel loads dashboard data from repositories', () async {
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: const _FakeInventoryRepository(),
      documentsRepository: const _FakeDocumentsRepository(),
      reportsRepository: const _FakeReportsRepository(),
    );

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);

    await loadFuture;

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.greeting, '你好，系统管理员');
    expect(viewModel.metrics.map((metric) => metric.value), [
      '12',
      '3,456',
      '2',
    ]);
    expect(viewModel.quickActions.map((action) => action.label), [
      '扫码销售',
      '退货',
      '入库',
      '调拨',
      '盘点',
      '转标准',
    ]);
    expect(viewModel.warnings.single.label, '低库存');
    expect(viewModel.warnings.single.count, 2);
    expect(viewModel.recentDocuments, [_recentDocument]);
  });

  test('operator quick actions hide admin-only document workflows', () {
    final viewModel = HomeViewModel(user: _operatorUser);

    expect(viewModel.quickActions.map((action) => action.label), [
      '扫码销售',
      '退货',
      '入库',
      '盘点',
    ]);
    expect(
      viewModel.quickActions.map((action) => action.documentActionLabel),
      isNot(contains('调拨单')),
    );
    expect(
      viewModel.quickActions.map((action) => action.documentActionLabel),
      isNot(contains('转标准')),
    );
  });

  test('document failure is scoped to recent documents section', () async {
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: const _FakeInventoryRepository(),
      documentsRepository: const _FailingDocumentsRepository(),
      reportsRepository: const _FakeReportsRepository(),
    );

    await viewModel.load();

    expect(viewModel.errorMessage, isNull);
    expect(viewModel.recentDocumentsErrorMessage, '最近单据不可用');
    expect(viewModel.metrics.map((metric) => metric.value), [
      '12',
      '3,456',
      '2',
    ]);
    expect(viewModel.warnings.single.label, '低库存');
    expect(viewModel.recentDocuments, isEmpty);
  });

  test('reload failure keeps previously loaded dashboard data', () async {
    final inventoryRepository = _SequentialHomeInventoryRepository();
    final reportsRepository = _SequentialHomeReportsRepository();
    final documentsRepository = _SequentialHomeDocumentsRepository();
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: inventoryRepository,
      documentsRepository: documentsRepository,
      reportsRepository: reportsRepository,
    );

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '库存服务短暂不可用');
    expect(viewModel.recentDocumentsErrorMessage, '最近单据刷新失败');
    expect(viewModel.metrics.map((metric) => metric.value), [
      '12',
      '3,456',
      '2',
    ]);
    expect(viewModel.warnings.single.label, '低库存');
    expect(viewModel.warnings.single.count, 2);
    expect(viewModel.recentDocuments, [_recentDocument]);
  });

  test(
    'inventory alert failure falls back to inventory list warnings',
    () async {
      final viewModel = HomeViewModel(
        user: _user,
        warehouse: _warehouse,
        inventoryRepository: const _FailingAlertsInventoryRepository(),
        documentsRepository: const _FakeDocumentsRepository(),
        reportsRepository: const _FakeReportsRepository(),
      );

      await viewModel.load();

      expect(viewModel.errorMessage, isNull);
      expect(viewModel.warnings.single.label, '低库存');
      expect(viewModel.warnings.single.count, 1);
      expect(viewModel.recentDocuments, [_recentDocument]);
    },
  );

  test(
    'inventory overview failure falls back to inventory list metrics',
    () async {
      final viewModel = HomeViewModel(
        user: _user,
        warehouse: _warehouse,
        inventoryRepository: const _FakeInventoryRepository(),
        documentsRepository: const _FakeDocumentsRepository(),
        reportsRepository: const _FailingOverviewReportsRepository(),
      );

      await viewModel.load();

      expect(viewModel.errorMessage, isNull);
      expect(viewModel.metrics.map((metric) => metric.value), [
        '2',
        '153',
        '2',
      ]);
      expect(viewModel.warnings.single.label, '低库存');
      expect(viewModel.recentDocuments, [_recentDocument]);
    },
  );

  test('non-standard warning uses non-standard inventory endpoint', () async {
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: const _FakeInventoryRepository(
        nonStandardItems: [_nonStandardItem, _nonStandardItemTwo],
      ),
      documentsRepository: const _FakeDocumentsRepository(),
      reportsRepository: const _FakeReportsRepository(),
    );

    await viewModel.load();

    final warningCounts = {
      for (final warning in viewModel.warnings) warning.label: warning.count,
    };
    expect(warningCounts['低库存'], 2);
    expect(warningCounts['非标库存'], 2);
  });

  testWidgets('RecentDocumentTile maps document status to semantic chip', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RecentDocumentTile(
                document: DocumentRecord(
                  id: 901,
                  docType: 2,
                  title: '销售单',
                  number: 'XS20260706006',
                  status: '草稿',
                ),
              ),
              RecentDocumentTile(
                document: DocumentRecord(
                  id: 902,
                  docType: 5,
                  title: '盘点单',
                  number: 'PD20260706006',
                  status: '已结转',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<RimsStatusChip>(find.widgetWithText(RimsStatusChip, '草稿'))
          .kind,
      RimsStatusKind.warning,
    );
    expect(
      tester
          .widget<RimsStatusChip>(find.widgetWithText(RimsStatusChip, '已结转'))
          .kind,
      RimsStatusKind.success,
    );
  });

  testWidgets('HomePage does not overflow on narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          user: _user,
          warehouse: _warehouse,
          inventoryRepository: const _FakeInventoryRepository(),
          documentsRepository: const _FakeDocumentsRepository(),
          reportsRepository: const _FakeReportsRepository(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('HomePage reloads when global refresh is requested', (
    tester,
  ) async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);
    final inventoryRepository = _CountingInventoryRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          user: _user,
          warehouse: _warehouse,
          eventBus: eventBus,
          inventoryRepository: inventoryRepository,
          documentsRepository: const _FakeDocumentsRepository(),
          reportsRepository: const _FakeReportsRepository(),
        ),
      ),
    );
    await tester.pump();

    expect(inventoryRepository.listInventoryCallCount, 1);

    eventBus.publish(const GlobalRefreshRequestedEvent());
    await tester.pump();
    await tester.pump();

    expect(inventoryRepository.listInventoryCallCount, 2);
  });

  testWidgets('HomePage retries loading after an error', (tester) async {
    final inventoryRepository = _RetryInventoryRepository();
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: inventoryRepository,
      documentsRepository: const _FakeDocumentsRepository(),
      reportsRepository: const _FakeReportsRepository(),
    );
    await viewModel.load();

    await tester.pumpWidget(MaterialApp(home: HomePage(viewModel: viewModel)));
    await tester.pump();

    expect(find.text('库存服务不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(find.text('正在加载库存预警...'), findsOneWidget);

    inventoryRepository.completeRetryInventory();
    await tester.pumpAndSettle();

    expect(inventoryRepository.listInventoryCallCount, 2);
    expect(find.text('库存服务不可用'), findsNothing);
    expect(find.text('低库存'), findsOneWidget);
  });
}

const _user = AppUser(
  id: 1,
  username: 'admin',
  realName: '系统管理员',
  roleCode: 'admin',
  roleName: '管理员',
);

const _operatorUser = AppUser(
  id: 2,
  username: 'operator',
  realName: '操作员',
  roleCode: 'user',
  roleName: '普通用户',
);

const _warehouse = Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true);

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

const _recentDocument = DocumentRecord(
  id: 1,
  docType: 2,
  title: '销售出库',
  number: 'SO-20260626-001',
  status: '待提交',
  productName: '矿泉水 550ml',
  quantity: 3,
);

const _nonStandardItem = NonStandardInventoryItem(
  id: 101,
  tempLabel: '临时瓶装水',
  description: '',
  unit: '箱',
  quantity: 10,
  convertedQuantity: 0,
  remainingQuantity: 10,
  status: 1,
);

const _nonStandardItemTwo = NonStandardInventoryItem(
  id: 102,
  tempLabel: '待转换纸巾',
  description: '',
  unit: '包',
  quantity: 5,
  convertedQuantity: 0,
  remainingQuantity: 5,
  status: 1,
);

final class _FakeInventoryRepository implements InventoryRepository {
  const _FakeInventoryRepository({this.nonStandardItems = const []});

  final List<NonStandardInventoryItem> nonStandardItems;

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<InventoryItem>>([_standardItem, _lowStockItem]);
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return const Success<List<InventoryItem>>([_lowStockItem, _lowStockItem]);
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success<List<NonStandardInventoryItem>>(nonStandardItems);
  }
}

final class _CountingInventoryRepository implements InventoryRepository {
  int listInventoryCallCount = 0;

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    listInventoryCallCount += 1;
    return const Success<List<InventoryItem>>([_standardItem, _lowStockItem]);
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return const Success<List<InventoryItem>>([_lowStockItem]);
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return const Success<List<NonStandardInventoryItem>>([]);
  }
}

final class _FailingAlertsInventoryRepository implements InventoryRepository {
  const _FailingAlertsInventoryRepository();

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<InventoryItem>>([_standardItem, _lowStockItem]);
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return const FailureResult<List<InventoryItem>>(
      NetworkFailure(message: '库存预警不可用'),
    );
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return const Success<List<NonStandardInventoryItem>>([]);
  }
}

final class _RetryInventoryRepository implements InventoryRepository {
  int listInventoryCallCount = 0;
  Completer<List<InventoryItem>>? _retryInventoryCompleter;

  void completeRetryInventory() {
    _retryInventoryCompleter?.complete([_standardItem, _lowStockItem]);
  }

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    listInventoryCallCount += 1;
    if (listInventoryCallCount == 1) {
      return const FailureResult<List<InventoryItem>>(
        NetworkFailure(message: '库存服务不可用'),
      );
    }

    _retryInventoryCompleter = Completer<List<InventoryItem>>();
    return Success<List<InventoryItem>>(await _retryInventoryCompleter!.future);
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    if (listInventoryCallCount == 1) {
      return const FailureResult<List<InventoryItem>>(
        NetworkFailure(message: '库存预警不可用'),
      );
    }

    return const Success<List<InventoryItem>>([_lowStockItem]);
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return const Success<List<NonStandardInventoryItem>>([]);
  }
}

final class _SequentialHomeInventoryRepository implements InventoryRepository {
  int listInventoryCallCount = 0;
  int listInventoryAlertsCallCount = 0;
  int listNonStandardInventoryCallCount = 0;

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    listInventoryCallCount += 1;
    if (listInventoryCallCount == 1) {
      return const Success<List<InventoryItem>>([_standardItem, _lowStockItem]);
    }

    return const FailureResult<List<InventoryItem>>(
      NetworkFailure(message: '库存服务短暂不可用'),
    );
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    listInventoryAlertsCallCount += 1;
    if (listInventoryAlertsCallCount == 1) {
      return const Success<List<InventoryItem>>([_lowStockItem, _lowStockItem]);
    }

    return const FailureResult<List<InventoryItem>>(
      NetworkFailure(message: '库存预警短暂不可用'),
    );
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    listNonStandardInventoryCallCount += 1;
    if (listNonStandardInventoryCallCount == 1) {
      return const Success<List<NonStandardInventoryItem>>([]);
    }

    return const FailureResult<List<NonStandardInventoryItem>>(
      NetworkFailure(message: '非标库存短暂不可用'),
    );
  }
}

final class _FakeReportsRepository implements ReportsRepository {
  const _FakeReportsRepository();

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<SalesStats>(
      SalesStats(revenue: 0, orderCount: 0, skuCount: 0, quantity: 0),
    );
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<List<SalesTrendPoint>>([]);
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    return const Success<List<SalesRankingItem>>([]);
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    return const Success<List<InventoryOverviewItem>>([
      InventoryOverviewItem(label: '商品数', value: 12),
      InventoryOverviewItem(label: '库存总量', value: 3456),
      InventoryOverviewItem(label: '预警数量', value: 2),
    ]);
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    return const Success<List<InventoryTurnoverItem>>([]);
  }

  @override
  Future<Result<List<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    return const Success<List<SlowMovingInventoryItem>>([]);
  }
}

final class _SequentialHomeReportsRepository implements ReportsRepository {
  int loadInventoryOverviewCallCount = 0;

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<SalesStats>(
      SalesStats(revenue: 0, orderCount: 0, skuCount: 0, quantity: 0),
    );
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<List<SalesTrendPoint>>([]);
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    return const Success<List<SalesRankingItem>>([]);
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    loadInventoryOverviewCallCount += 1;
    if (loadInventoryOverviewCallCount == 1) {
      return const Success<List<InventoryOverviewItem>>([
        InventoryOverviewItem(label: '商品数', value: 12),
        InventoryOverviewItem(label: '库存总量', value: 3456),
        InventoryOverviewItem(label: '预警数量', value: 2),
      ]);
    }

    return const FailureResult<List<InventoryOverviewItem>>(
      NetworkFailure(message: '库存概览短暂不可用'),
    );
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    return const Success<List<InventoryTurnoverItem>>([]);
  }

  @override
  Future<Result<List<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    return const Success<List<SlowMovingInventoryItem>>([]);
  }
}

final class _FailingOverviewReportsRepository implements ReportsRepository {
  const _FailingOverviewReportsRepository();

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<SalesStats>(
      SalesStats(revenue: 0, orderCount: 0, skuCount: 0, quantity: 0),
    );
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<List<SalesTrendPoint>>([]);
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    return const Success<List<SalesRankingItem>>([]);
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    return const FailureResult<List<InventoryOverviewItem>>(
      NetworkFailure(message: '库存概览不可用'),
    );
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    return const Success<List<InventoryTurnoverItem>>([]);
  }

  @override
  Future<Result<List<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    return const Success<List<SlowMovingInventoryItem>>([]);
  }
}

final class _FakeDocumentsRepository implements DocumentsRepository {
  const _FakeDocumentsRepository();

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    return const Success<List<DocumentRecord>>([_recentDocument]);
  }

  @override
  Future<Result<List<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<TransactionRecord>>([]);
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(_recentDocument);
  }

  @override
  Future<Result<void>> completeDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    return const Success<void>(null);
  }
}

final class _FailingDocumentsRepository implements DocumentsRepository {
  const _FailingDocumentsRepository();

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    return const FailureResult<List<DocumentRecord>>(
      NetworkFailure(message: '最近单据不可用'),
    );
  }

  @override
  Future<Result<List<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<TransactionRecord>>([]);
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(_recentDocument);
  }

  @override
  Future<Result<void>> completeDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    return const Success<void>(null);
  }
}

final class _SequentialHomeDocumentsRepository implements DocumentsRepository {
  int listRecentDocumentsCallCount = 0;

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    listRecentDocumentsCallCount += 1;
    if (listRecentDocumentsCallCount == 1) {
      return const Success<List<DocumentRecord>>([_recentDocument]);
    }

    return const FailureResult<List<DocumentRecord>>(
      NetworkFailure(message: '最近单据刷新失败'),
    );
  }

  @override
  Future<Result<List<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<TransactionRecord>>([]);
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(_recentDocument);
  }

  @override
  Future<Result<void>> completeDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    return const Success<void>(null);
  }
}
