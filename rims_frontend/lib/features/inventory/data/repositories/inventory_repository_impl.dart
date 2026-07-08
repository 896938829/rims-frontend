import '../../../../core/result/result.dart';
import '../../domain/entities/inventory_item.dart';
import '../../domain/entities/non_standard_inventory_item.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../datasources/inventory_remote_datasource.dart';

final class InventoryRepositoryImpl implements InventoryRepository {
  const InventoryRepositoryImpl({required this.remoteDataSource});

  final InventoryRemoteDataSource remoteDataSource;

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listInventory(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<InventoryItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<InventoryItem>>.new,
    );
  }

  @override
  Future<Result<List<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    final result = await remoteDataSource.listInventoryAlerts(page: page);

    return result.when(
      success: (models) => Success<List<InventoryItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<InventoryItem>>.new,
    );
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    final result = await remoteDataSource.findProductByBarcode(barcode);

    return result.when(
      success: (model) => Success<InventoryItem>(model.toEntity()),
      failure: FailureResult<InventoryItem>.new,
    );
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    final result = await remoteDataSource.updateInventorySettings(
      inventoryId: inventoryId,
      alertThreshold: alertThreshold,
      status: status,
    );

    return result.when(
      success: (model) => Success<InventoryItem>(model.toEntity()),
      failure: FailureResult<InventoryItem>.new,
    );
  }

  @override
  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    final result = await remoteDataSource.listNonStandardInventory(page: page);

    return result.when(
      success: (models) => Success<List<NonStandardInventoryItem>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<NonStandardInventoryItem>>.new,
    );
  }
}
