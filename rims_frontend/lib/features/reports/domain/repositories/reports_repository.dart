import '../../../../core/result/result.dart';
import '../entities/report_data.dart';

abstract interface class ReportsRepository {
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview();
}
