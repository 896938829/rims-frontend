import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';

import '../../integration_test/support/m11_journey_fixtures.dart';

void main() {
  test('selects the first active fixture with enough available stock', () {
    final selected = selectM11SalesFixture([
      _item('M9-PAGE-0001', available: 2),
      _item('M9-PAGE-0002', available: 20, status: 0),
      _item('OTHER-0001', available: 30),
      _item('M9-PAGE-0007', available: 27),
      _item('M9-PAGE-0006', available: 26),
    ]);

    expect(selected.sku, 'M9-PAGE-0006');
  });

  test('fails when no cached fixture can cover the journey', () {
    expect(
      () => selectM11SalesFixture([
        _item('M9-PAGE-0001', available: 2),
        _item('M9-PAGE-0002', available: 5),
      ]),
      throwsStateError,
    );
  });
}

InventoryItem _item(String sku, {required int available, int status = 1}) {
  return InventoryItem(
    id: sku.hashCode,
    productId: sku.hashCode,
    productName: sku,
    sku: sku,
    availableQuantity: available,
    stockQuantity: available,
    statusLabel: status == 1 ? '正常' : '停用',
    imageUrl: '',
    status: status,
    retailPrice: 1,
  );
}
