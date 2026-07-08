final class SalesStats {
  const SalesStats({
    required this.revenue,
    required this.orderCount,
    required this.skuCount,
    required this.quantity,
    this.costAmount,
    this.grossProfit,
  });

  final double revenue;
  final int orderCount;
  final int skuCount;
  final int quantity;
  final double? costAmount;
  final double? grossProfit;
}

final class SalesTrendPoint {
  const SalesTrendPoint({required this.date, required this.amount});

  final String date;
  final double amount;
}

final class SalesRankingItem {
  const SalesRankingItem({required this.productName, required this.amount});

  final String productName;
  final double amount;
}

final class InventoryOverviewItem {
  const InventoryOverviewItem({required this.label, required this.value});

  final String label;
  final double value;
}

final class InventoryTurnoverItem {
  const InventoryTurnoverItem({
    required this.productName,
    required this.sku,
    required this.soldQuantity,
    required this.averageStockQuantity,
    required this.turnoverRate,
  });

  final String productName;
  final String sku;
  final int soldQuantity;
  final double averageStockQuantity;
  final double turnoverRate;
}

final class SlowMovingInventoryItem {
  const SlowMovingInventoryItem({
    required this.productName,
    required this.sku,
    required this.stockQuantity,
    required this.salesQuantity,
    this.lastSaleAt,
  });

  final String productName;
  final String sku;
  final int stockQuantity;
  final int salesQuantity;
  final String? lastSaleAt;
}
