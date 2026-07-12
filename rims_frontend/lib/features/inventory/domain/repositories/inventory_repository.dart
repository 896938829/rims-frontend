import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../entities/inventory_item.dart';
import '../entities/non_standard_inventory_item.dart';

enum InventoryDataSource { network, cache }

final class InventoryReadStatus {
  const InventoryReadStatus({
    required this.source,
    required this.fetchedAt,
    required this.expiresAt,
  });

  final InventoryDataSource source;
  final DateTime fetchedAt;
  final DateTime expiresAt;

  bool get isCached => source == InventoryDataSource.cache;
}

abstract interface class InventoryReadMetadata {
  InventoryReadStatus? get lastReadStatus;
}

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
