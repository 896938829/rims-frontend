import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';

void main() {
  test('DocumentsViewModel exposes static document workflow data', () {
    const viewModel = DocumentsViewModel();

    expect(viewModel.actions, hasLength(6));
    expect(viewModel.flowSteps, ['创建', '确认', '提交', '完成']);
    expect(viewModel.recentDocuments, hasLength(3));
    expect(viewModel.actions.first.label, '销售出库');
  });
}
