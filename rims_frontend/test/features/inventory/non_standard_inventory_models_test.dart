import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/data/models/inventory_models.dart';

void main() {
  test('NonStandardInventoryItemModel parses backend response', () {
    final model = NonStandardInventoryItemModel.fromJson({
      'id': 11,
      'warehouseId': 1,
      'tempLabel': 'TMP-20260627-001',
      'description': '破损瓶临时集合',
      'unit': '件',
      'quantity': 5,
      'convertedQty': 1,
      'remainingQty': 4,
      'status': 1,
    });

    final item = model.toEntity();

    expect(item.id, 11);
    expect(item.tempLabel, 'TMP-20260627-001');
    expect(item.description, '破损瓶临时集合');
    expect(item.unit, '件');
    expect(item.quantity, 5);
    expect(item.convertedQuantity, 1);
    expect(item.remainingQuantity, 4);
    expect(item.status, 1);
  });
}
