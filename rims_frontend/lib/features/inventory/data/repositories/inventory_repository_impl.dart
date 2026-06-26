import '../../../../core/result/result.dart';
import '../../domain/entities/inventory_item.dart';
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
}
