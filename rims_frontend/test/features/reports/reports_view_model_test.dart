import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/reports/domain/entities/report_data.dart';
import 'package:rims_frontend/features/reports/domain/repositories/reports_repository.dart';
import 'package:rims_frontend/features/reports/presentation/pages/reports_page.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';
import 'package:rims_frontend/features/reports/presentation/widgets/report_ranking_bar.dart';

void main() {
  test(
    'load computes current date range and exposes repository data',
    () async {
      final repository = _FakeReportsRepository();
      final viewModel = ReportsViewModel(
        repository: repository,
        today: DateTime(2026, 6, 26),
      );

      final loadFuture = viewModel.load();

      expect(viewModel.isLoading, isTrue);

      await loadFuture;

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.errorMessage, isNull);
      expect(viewModel.dateRangeLabel, '2026-06-20 ~ 2026-06-26');
      expect(repository.lastStartDate, DateTime(2026, 6, 20));
      expect(repository.lastEndDate, DateTime(2026, 6, 26));
      expect(repository.lastStatsStartDate, DateTime(2026, 6, 20));
      expect(repository.lastStatsEndDate, DateTime(2026, 6, 26));
      expect(viewModel.summaryMetrics.map((metric) => metric.label), [
        '销售额',
        '订单数',
        '销量',
      ]);
      expect(viewModel.summaryMetrics.map((metric) => metric.value), [
        '¥12,345',
        '8',
        '32',
      ]);
      expect(viewModel.trendPoints, [100, 230]);
      expect(viewModel.rankings.first.name, '真实商品');
      expect(viewModel.rankings.first.amountLabel, '¥12,345');
      expect(viewModel.inventoryBuckets.map((bucket) => bucket.label), [
        '正常库存',
        '低库存',
      ]);
      expect(viewModel.turnoverItems.first.name, '矿泉水');
      expect(viewModel.turnoverItems.first.rateLabel, '2.50 次');
      expect(viewModel.turnoverItems.first.detailLabel, '售出 20 / 均库 10');
      expect(viewModel.slowMovingItems.first.name, '纸巾');
      expect(viewModel.slowMovingItems.first.detailLabel, '销量 0 / 库存 80');
      expect(viewModel.slowMovingItems.first.lastSaleLabel, '最近销售 2026-05-01');
      expect(viewModel.slowMovingTotal, 8);
    },
  );

  test('selectPeriod reloads with dynamic thirty-day range', () async {
    final repository = _FakeReportsRepository();
    final viewModel = ReportsViewModel(
      repository: repository,
      today: DateTime(2026, 6, 26),
    );

    await viewModel.selectPeriod('近30天');

    expect(viewModel.selectedPeriodLabel, '近30天');
    expect(viewModel.dateRangeLabel, '2026-05-28 ~ 2026-06-26');
    expect(repository.lastStartDate, DateTime(2026, 5, 28));
    expect(repository.lastEndDate, DateTime(2026, 6, 26));
  });

  test(
    'failure exposes user-facing error and clears stale report data',
    () async {
      final repository = _FakeReportsRepository(
        trendResult: const FailureResult<List<SalesTrendPoint>>(
          NetworkFailure(message: '报表服务不可用'),
        ),
      );
      final viewModel = ReportsViewModel(
        repository: repository,
        today: DateTime(2026, 6, 26),
      );

      await viewModel.load();

      expect(viewModel.isLoading, isFalse);
      expect(viewModel.errorMessage, '报表服务不可用');
      expect(viewModel.summaryMetrics, isEmpty);
      expect(viewModel.trendPoints, isEmpty);
      expect(viewModel.rankings, isEmpty);
      expect(viewModel.inventoryBuckets, isEmpty);
      expect(viewModel.turnoverItems, isEmpty);
      expect(viewModel.slowMovingItems, isEmpty);
    },
  );

  test('sales stats failure exposes user-facing error', () async {
    final repository = _FakeReportsRepository(
      statsResult: const FailureResult<SalesStats>(
        NetworkFailure(message: '销售统计不可用'),
      ),
    );
    final viewModel = ReportsViewModel(
      repository: repository,
      today: DateTime(2026, 6, 26),
    );

    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '销售统计不可用');
    expect(viewModel.summaryMetrics, isEmpty);
    expect(viewModel.trendPoints, isEmpty);
  });

  test(
    'inventory report failure keeps financial metrics and exposes section error',
    () async {
      final repository = _FakeReportsRepository(
        overviewResult: const Success<List<InventoryOverviewItem>>([
          InventoryOverviewItem(label: '正常库存', value: 80),
          InventoryOverviewItem(label: '低库存', value: 20),
        ]),
        turnoverResult: const FailureResult<List<InventoryTurnoverItem>>(
          NetworkFailure(message: '库存周转不可用'),
        ),
        slowMovingResult: Success<PageData<SlowMovingInventoryItem>>(
          PageData(
            items: const [
              SlowMovingInventoryItem(
                productName: '纸巾',
                sku: 'SKU-TI',
                stockQuantity: 80,
                salesQuantity: 0,
                lastSaleAt: '2026-05-01',
              ),
            ],
            total: 1,
            page: 1,
            pageSize: 5,
          ),
        ),
      );
      final viewModel = ReportsViewModel(
        repository: repository,
        today: DateTime(2026, 6, 26),
      );

      await viewModel.load();

      expect(viewModel.errorMessage, isNull);
      expect(viewModel.inventoryReportErrorMessage, '库存周转不可用');
      expect(viewModel.summaryMetrics, isNotEmpty);
      expect(viewModel.trendPoints, [100, 230]);
      expect(viewModel.rankings.first.name, '真实商品');
      expect(viewModel.inventoryBuckets, isNotEmpty);
      expect(viewModel.turnoverItems, isEmpty);
      expect(viewModel.slowMovingItems, isNotEmpty);
    },
  );

  test('regular user skips financial trend and ranking endpoints', () async {
    final repository = _FakeReportsRepository(
      trendResult: const FailureResult<List<SalesTrendPoint>>(
        AuthorizationFailure(message: '无权查看销售趋势'),
      ),
      rankingResult: const FailureResult<List<SalesRankingItem>>(
        AuthorizationFailure(message: '无权查看销售排行'),
      ),
    );
    final viewModel = ReportsViewModel(
      repository: repository,
      canViewFinancialMetrics: false,
      today: DateTime(2026, 6, 26),
    );

    await viewModel.load();

    expect(viewModel.errorMessage, isNull);
    expect(viewModel.summaryMetrics, isEmpty);
    expect(viewModel.trendPoints, isEmpty);
    expect(viewModel.rankings, isEmpty);
    expect(viewModel.inventoryBuckets, isNotEmpty);
    expect(viewModel.turnoverItems, isNotEmpty);
    expect(viewModel.slowMovingItems, isNotEmpty);
    expect(repository.statsCallCount, 0);
    expect(repository.trendCallCount, 0);
    expect(repository.rankingCallCount, 0);
  });

  test(
    'regular user skips sales stats endpoint when financial metrics are hidden',
    () async {
      final repository = _FakeReportsRepository(
        statsResult: const FailureResult<SalesStats>(
          AuthorizationFailure(message: '无权查看销售汇总'),
        ),
      );
      final viewModel = ReportsViewModel(
        repository: repository,
        canViewFinancialMetrics: false,
        today: DateTime(2026, 6, 26),
      );

      await viewModel.load();

      expect(viewModel.errorMessage, isNull);
      expect(viewModel.summaryMetrics, isEmpty);
      expect(viewModel.inventoryBuckets, isNotEmpty);
      expect(viewModel.turnoverItems, isNotEmpty);
      expect(viewModel.slowMovingItems, isNotEmpty);
      expect(repository.statsCallCount, 0);
      expect(repository.trendCallCount, 0);
      expect(repository.rankingCallCount, 0);
    },
  );

  testWidgets('ReportsPage does not overflow at narrow width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ReportsPage(
          viewModel: ReportsViewModel(
            repository: _FakeReportsRepository(),
            today: DateTime(2026, 6, 26),
          )..load(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('ReportsPage retries loading after an error', (tester) async {
    final repository = _RetryReportsRepository();
    final viewModel = ReportsViewModel(
      repository: repository,
      today: DateTime(2026, 6, 26),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(home: ReportsPage(viewModel: viewModel)),
    );
    await tester.pump();

    expect(find.text('销售统计不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(find.text('正在加载报表...'), findsOneWidget);

    repository.completeRetryStats();
    await tester.pumpAndSettle();

    expect(repository.statsCallCount, 2);
    expect(find.text('销售统计不可用'), findsNothing);
    expect(find.text('真实商品'), findsOneWidget);
  });

  testWidgets(
    'ReportsPage shows inventory report section error with sales data',
    (tester) async {
      final viewModel = ReportsViewModel(
        repository: _FakeReportsRepository(
          turnoverResult: const FailureResult<List<InventoryTurnoverItem>>(
            NetworkFailure(message: '库存周转不可用'),
          ),
        ),
        today: DateTime(2026, 6, 26),
      );
      await viewModel.load();

      await tester.pumpWidget(
        MaterialApp(home: ReportsPage(viewModel: viewModel)),
      );

      expect(find.text('销售统计'), findsOneWidget);
      expect(find.text('真实商品'), findsOneWidget);
      expect(find.text('库存周转不可用'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    },
  );

  testWidgets('ReportRankingBar constrains long amount labels', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: ReportRankingBar(
              ranking: ReportRanking(
                name: '超长商品名称',
                value: 100,
                amountLabel: '人民币 123,456,789.00 元',
              ),
              maxValue: 100,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

final class _RetryReportsRepository extends _FakeReportsRepository {
  Completer<SalesStats>? _retryStatsCompleter;

  void completeRetryStats() {
    _retryStatsCompleter?.complete(
      const SalesStats(
        revenue: 12345,
        orderCount: 8,
        skuCount: 3,
        quantity: 32,
      ),
    );
  }

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    statsCallCount += 1;
    if (statsCallCount == 1) {
      return const FailureResult<SalesStats>(
        NetworkFailure(message: '销售统计不可用'),
      );
    }

    lastStatsStartDate = startDate;
    lastStatsEndDate = endDate;
    _retryStatsCompleter = Completer<SalesStats>();
    return Success<SalesStats>(await _retryStatsCompleter!.future);
  }
}

final class _FakeReportsRepository implements ReportsRepository {
  _FakeReportsRepository({
    this.statsResult = const Success<SalesStats>(
      SalesStats(revenue: 12345, orderCount: 8, skuCount: 3, quantity: 32),
    ),
    this.trendResult = const Success<List<SalesTrendPoint>>([
      SalesTrendPoint(date: '2026-06-25', amount: 100),
      SalesTrendPoint(date: '2026-06-26', amount: 230),
    ]),
    this.rankingResult = const Success<List<SalesRankingItem>>([
      SalesRankingItem(productName: '真实商品', amount: 12345),
    ]),
    this.overviewResult = const Success<List<InventoryOverviewItem>>([
      InventoryOverviewItem(label: '正常库存', value: 80),
      InventoryOverviewItem(label: '低库存', value: 20),
    ]),
    this.turnoverResult = const Success<List<InventoryTurnoverItem>>([
      InventoryTurnoverItem(
        productName: '矿泉水',
        sku: 'SKU-WA',
        soldQuantity: 20,
        averageStockQuantity: 10,
        turnoverRate: 2.5,
      ),
    ]),
    Result<PageData<SlowMovingInventoryItem>>? slowMovingResult,
  }) : slowMovingResult =
           slowMovingResult ??
           Success<PageData<SlowMovingInventoryItem>>(
             PageData(
               items: [
                 const SlowMovingInventoryItem(
                   productName: '纸巾',
                   sku: 'SKU-TI',
                   stockQuantity: 80,
                   salesQuantity: 0,
                   lastSaleAt: '2026-05-01',
                 ),
               ],
               total: 8,
               page: 1,
               pageSize: 5,
             ),
           );

  final Result<SalesStats> statsResult;
  final Result<List<SalesTrendPoint>> trendResult;
  final Result<List<SalesRankingItem>> rankingResult;
  final Result<List<InventoryOverviewItem>> overviewResult;
  final Result<List<InventoryTurnoverItem>> turnoverResult;
  final Result<PageData<SlowMovingInventoryItem>> slowMovingResult;
  DateTime? lastStatsStartDate;
  DateTime? lastStatsEndDate;
  DateTime? lastStartDate;
  DateTime? lastEndDate;
  int statsCallCount = 0;
  int trendCallCount = 0;
  int rankingCallCount = 0;

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    statsCallCount += 1;
    lastStatsStartDate = startDate;
    lastStatsEndDate = endDate;
    return statsResult;
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    trendCallCount += 1;
    lastStartDate = startDate;
    lastEndDate = endDate;
    return trendResult;
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    rankingCallCount += 1;
    return rankingResult;
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    return overviewResult;
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    return turnoverResult;
  }

  @override
  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    return slowMovingResult;
  }
}
