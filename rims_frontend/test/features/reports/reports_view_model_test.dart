import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';

void main() {
  test('ReportsViewModel exposes static report data', () {
    const viewModel = ReportsViewModel();

    expect(viewModel.dateRangeLabel, '2024-05-12 ~ 2024-05-18');
    expect(viewModel.trendPoints, hasLength(7));
    expect(viewModel.rankings, hasLength(5));
    expect(viewModel.inventoryBuckets, hasLength(4));
  });
}
