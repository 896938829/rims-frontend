import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_reports_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/reports/domain/entities/report_data.dart';
import 'package:rims_frontend/features/reports/domain/repositories/reports_repository.dart';
import 'package:rims_frontend/features/reports/presentation/pages/reports_page.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';

void main() {
  var canViewFinancial = true;
  final start = DateTime(2026, 7, 1);
  final end = DateTime(2026, 7, 13);
  late _FakeReportsRepository delegate;
  late CachedReportsRepository repository;

  setUp(() {
    canViewFinancial = true;
    delegate = _FakeReportsRepository();
    repository = CachedReportsRepository(
      delegate: delegate,
      store: MemoryOfflineStore(),
      accountIdReader: () => '7',
      warehouseIdReader: () => 11,
      canViewFinancialMetricsReader: () => canViewFinancial,
      now: () => DateTime.utc(2026, 7, 13, 12),
    );
  });

  test('query-specific stats fall back with source metadata', () async {
    delegate.statsResult = const Success(
      SalesStats(
        revenue: 100,
        orderCount: 2,
        skuCount: 3,
        quantity: 4,
        costAmount: 60,
        grossProfit: 40,
      ),
    );
    await repository.loadSalesStats(startDate: start, endDate: end);
    delegate.statsResult = const FailureResult(NetworkFailure());

    final result = await repository.loadSalesStats(
      startDate: start,
      endDate: end,
    );

    expect(result.isSuccess, isTrue);
    expect(repository.lastReadStatus?.source, ReportDataSource.cache);
    expect(
      await repository.loadSalesStats(
        startDate: start.subtract(const Duration(days: 1)),
        endDate: end,
      ),
      isA<FailureResult>(),
    );
  });

  test('ordinary-user view never reuses admin financial cache', () async {
    delegate.statsResult = const Success(
      SalesStats(
        revenue: 100,
        orderCount: 2,
        skuCount: 3,
        quantity: 4,
        costAmount: 60,
        grossProfit: 40,
      ),
    );
    await repository.loadSalesStats(startDate: start, endDate: end);
    canViewFinancial = false;
    delegate.statsResult = const FailureResult(NetworkFailure());

    expect(
      await repository.loadSalesStats(startDate: start, endDate: end),
      isA<FailureResult>(),
    );
  });

  test(
    'authorization failure remains visible despite matching cache',
    () async {
      delegate.statsResult = const Success(
        SalesStats(revenue: 0, orderCount: 1, skuCount: 1, quantity: 1),
      );
      await repository.loadSalesStats(startDate: start, endDate: end);
      delegate.statsResult = const FailureResult(AuthorizationFailure());

      expect(
        await repository.loadSalesStats(startDate: start, endDate: end),
        isA<FailureResult>(),
      );
    },
  );

  testWidgets('ordinary reports show cache status without financial sections', (
    tester,
  ) async {
    canViewFinancial = false;
    delegate.overviewResult = const Success([
      InventoryOverviewItem(label: '正常库存', value: 2),
    ]);
    await repository.loadInventoryOverview();
    delegate.overviewResult = const FailureResult(NetworkFailure());
    final viewModel = ReportsViewModel(
      repository: repository,
      canViewFinancialMetrics: false,
      today: DateTime(2026, 7, 13),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReportsPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('reports-cache-status')), findsOneWidget);
    expect(find.text('销售统计'), findsNothing);
    expect(find.text('销售趋势（元）'), findsNothing);
    expect(find.text('商品排行（销售额）'), findsNothing);
  });
}

final class _FakeReportsRepository implements ReportsRepository {
  Result<SalesStats> statsResult = const FailureResult(UnknownFailure());
  Result<List<InventoryOverviewItem>> overviewResult = const Success([]);

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async => statsResult;

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async => const Success([]);
  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async => const Success([]);
  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async =>
      overviewResult;
  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async => const Success([]);
  @override
  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async => Success(
    PageData(items: const [], total: 0, page: page, pageSize: pageSize),
  );
}
