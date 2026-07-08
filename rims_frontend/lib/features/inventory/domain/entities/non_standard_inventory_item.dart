final class NonStandardInventoryItem {
  const NonStandardInventoryItem({
    required this.id,
    required this.tempLabel,
    required this.description,
    required this.unit,
    required this.quantity,
    required this.convertedQuantity,
    required this.remainingQuantity,
    required this.status,
  });

  final int id;
  final String tempLabel;
  final String description;
  final String unit;
  final int quantity;
  final int convertedQuantity;
  final int remainingQuantity;
  final int status;

  String get displayName => tempLabel.isNotEmpty ? tempLabel : description;
}
