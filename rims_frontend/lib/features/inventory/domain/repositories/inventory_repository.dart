import '../../../../core/result/result.dart';
import '../entities/inventory_item.dart';

abstract interface class InventoryRepository {
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  });
}
