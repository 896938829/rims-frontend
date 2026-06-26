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
