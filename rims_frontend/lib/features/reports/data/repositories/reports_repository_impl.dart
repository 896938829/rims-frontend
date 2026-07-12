import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../../domain/entities/report_data.dart';
import '../../domain/repositories/reports_repository.dart';
import '../datasources/reports_remote_datasource.dart';

final class ReportsRepositoryImpl implements ReportsRepository {
  const ReportsRepositoryImpl({required this.remoteDataSource});

  final ReportsRemoteDataSource remoteDataSource;

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await remoteDataSource.loadSalesStats(
      startDate: startDate,
      endDate: endDate,
    );

    return result.when(
      success: (model) => Success<SalesStats>(model.toEntity()),
      failure: FailureResult<SalesStats>.new,
    );
  }

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await remoteDataSource.loadSalesTrend(
      startDate: startDate,
      endDate: endDate,
    );

    return result.when(
      success: (models) => Success<List<SalesTrendPoint>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<SalesTrendPoint>>.new,
    );
  }

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    final result = await remoteDataSource.loadSalesRanking(
      startDate: startDate,
      endDate: endDate,
      metric: metric,
      limit: limit,
    );

    return result.when(
      success: (models) => Success<List<SalesRankingItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<SalesRankingItem>>.new,
    );
  }

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() async {
    final result = await remoteDataSource.loadInventoryOverview();

    return result.when(
      success: (models) => Success<List<InventoryOverviewItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<InventoryOverviewItem>>.new,
    );
  }

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    final result = await remoteDataSource.loadInventoryTurnover(
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );

    return result.when(
      success: (models) => Success<List<InventoryTurnoverItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<InventoryTurnoverItem>>.new,
    );
  }

  @override
  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    final result = await remoteDataSource.loadSlowMovingInventory(
      startDate: startDate,
      endDate: endDate,
      maxSales: maxSales,
      page: page,
      pageSize: pageSize,
    );

    return result.when(
      success: (page) => Success<PageData<SlowMovingInventoryItem>>(
        page.map((model) => model.toEntity()),
      ),
      failure: FailureResult<PageData<SlowMovingInventoryItem>>.new,
    );
  }
}
