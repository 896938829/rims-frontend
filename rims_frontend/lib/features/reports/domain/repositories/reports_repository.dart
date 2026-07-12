import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../entities/report_data.dart';

enum ReportDataSource { network, cache }

final class ReportReadStatus {
  const ReportReadStatus({
    required this.source,
    required this.fetchedAt,
    required this.expiresAt,
  });
  final ReportDataSource source;
  final DateTime fetchedAt;
  final DateTime expiresAt;
  bool get isCached => source == ReportDataSource.cache;
}

abstract interface class ReportReadMetadata {
  ReportReadStatus? get lastReadStatus;
}

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

  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  });
}
