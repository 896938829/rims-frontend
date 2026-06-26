final class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.availableQuantity,
    required this.stockQuantity,
    required this.statusLabel,
    required this.imageUrl,
  });

  final int id;
  final int productId;
  final String productName;
  final String sku;
  final int availableQuantity;
  final int stockQuantity;
  final String statusLabel;
  final String imageUrl;
}
