import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';

void main() {
  test('InventoryViewModel exposes static inventory data', () {
    const viewModel = InventoryViewModel();

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.tabs, ['标准', '商品', '非标']);
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.products, hasLength(4));
    expect(viewModel.products.first.name, '矿泉水 550ml');
  });
}
