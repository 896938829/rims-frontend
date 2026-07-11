import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../entities/inventory_item.dart';
import '../entities/non_standard_inventory_item.dart';

abstract interface class InventoryRepository {
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  });

  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({int page = 1});

  Future<Result<InventoryItem>> findProductByBarcode(String barcode);

  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  });

  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  });
}
