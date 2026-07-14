import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';

const int m11RequiredSalesStock = 6;

InventoryItem selectM11SalesFixture(
  Iterable<InventoryItem> items, {
  int requiredStock = m11RequiredSalesStock,
}) {
  final eligible =
      items
          .where(
            (item) =>
                item.sku.startsWith('M9-PAGE-') &&
                item.status == 1 &&
                item.availableQuantity >= requiredStock &&
                item.retailPrice != null,
          )
          .toList()
        ..sort((left, right) => left.sku.compareTo(right.sku));
  if (eligible.isEmpty) {
    throw StateError(
      'No cached M11 sales fixture has at least $requiredStock available units.',
    );
  }
  return eligible.first;
}
