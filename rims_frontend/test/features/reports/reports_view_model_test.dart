import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      expect(viewModel.trendPoints, [100, 230]);
      expect(viewModel.rankings.first.name, '真实商品');
      expect(viewModel.rankings.first.amountLabel, '¥12,345');
      expect(viewModel.inventoryBuckets.map((bucket) => bucket.label), [
        '正常库存',
        '低库存',
      ]);
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
      expect(viewModel.trendPoints, isEmpty);
      expect(viewModel.rankings, isEmpty);
      expect(viewModel.inventoryBuckets, isEmpty);
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

final class _FakeReportsRepository implements ReportsRepository {
  _FakeReportsRepository({
    this.trendResult = const Success<List<SalesTrendPoint>>([
      SalesTrendPoint(date: '2026-06-25', amount: 100),
      SalesTrendPoint(date: '2026-06-26', amount: 230),
    ]),
  });

  final Result<List<SalesTrendPoint>> trendResult;
  DateTime? lastStartDate;
  DateTime? lastEndDate;

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    lastStartDate = startDate;
    lastEndDate = endDate;
    return trendResult;
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    return const Success<List<SalesRankingItem>>([
      SalesRankingItem(productName: '真实商品', amount: 12345),
    ]);
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    return const Success<List<InventoryOverviewItem>>([
      InventoryOverviewItem(label: '正常库存', value: 80),
      InventoryOverviewItem(label: '低库存', value: 20),
    ]);
  }
}
