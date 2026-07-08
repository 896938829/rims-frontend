import '../../../../core/result/result.dart';
import '../entities/report_data.dart';

abstract interface class ReportsRepository {
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  });

  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview();

  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  });

  Future<Result<List<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  });
}
