import '../../../../core/result/result.dart';
import '../entities/inventory_item.dart';
import '../entities/non_standard_inventory_item.dart';

abstract interface class InventoryRepository {
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  });

  Future<Result<List<InventoryItem>>> listInventoryAlerts({int page = 1});

  Future<Result<InventoryItem>> findProductByBarcode(String barcode);

  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  });

  Future<Result<List<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  });
}
