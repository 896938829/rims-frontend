import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';

void main() {
  test('HomeViewModel exposes static dashboard data', () {
    const viewModel = HomeViewModel();

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.metrics, hasLength(3));
    expect(viewModel.quickActions, hasLength(4));
    expect(viewModel.warnings, hasLength(3));
    expect(viewModel.recentDocuments, hasLength(3));
  });
}
