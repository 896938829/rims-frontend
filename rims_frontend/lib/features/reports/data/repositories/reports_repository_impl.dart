import '../../../../core/result/result.dart';
import '../../domain/entities/report_data.dart';
import '../../domain/repositories/reports_repository.dart';
import '../datasources/reports_remote_datasource.dart';

final class ReportsRepositoryImpl implements ReportsRepository {
  const ReportsRepositoryImpl({required this.remoteDataSource});

  final ReportsRemoteDataSource remoteDataSource;

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
  }) async {
    final result = await remoteDataSource.loadSalesRanking(
      startDate: startDate,
      endDate: endDate,
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
}
