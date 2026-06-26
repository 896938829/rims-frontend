import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';

void main() {
  test('load exposes document actions and backend recent documents', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.actions, hasLength(6));
    expect(viewModel.flowSteps, ['创建', '确认', '提交', '完成']);
    expect(viewModel.recentDocuments, [_remoteDocument]);
    expect(viewModel.actions.first.label, '销售出库');
  });

  test('DocumentsViewModel selects document action', () {
    final viewModel = DocumentsViewModel();

    viewModel.selectActionByLabel('盘点单');

    expect(viewModel.selectedAction.label, '盘点单');
  });

  test('rejects empty quantity before creating document', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository)
      ..updateProductName('矿泉水 550ml')
      ..updateQuantity('');

    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '请输入商品和数量');
    expect(repository.createdRequest, isNull);
  });

  test('load exposes repository failure', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const FailureResult<List<DocumentRecord>>(
        NetworkFailure(message: '单据列表加载失败'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.errorMessage, '单据列表加载失败');
    expect(viewModel.recentDocuments, isEmpty);
  });

  test(
    'createDocument submits request and prepends backend document',
    () async {
      final repository = _FakeDocumentsRepository();
      final viewModel = DocumentsViewModel(repository: repository)
        ..selectActionByLabel('销售出库')
        ..updateProductName('矿泉水 550ml')
        ..updateQuantity('3');

      final created = await viewModel.createDocument();

      expect(created, isTrue);
      expect(viewModel.formError, isNull);
      expect(repository.createdRequest?.typeCode, 'SO');
      expect(repository.createdRequest?.productName, '矿泉水 550ml');
      expect(repository.createdRequest?.quantity, 3);
      expect(viewModel.recentDocuments.first.number, 'SO-20260626-001');
      expect(viewModel.recentDocuments.first.status, '待提交');
    },
  );

  test('createDocument surfaces repository failure', () async {
    final repository = _FakeDocumentsRepository(
      createResult: const FailureResult<DocumentRecord>(
        NetworkFailure(message: '单据服务不可用'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..updateProductName('矿泉水 550ml')
      ..updateQuantity('3');

    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '单据服务不可用');
    expect(viewModel.recentDocuments, isEmpty);
  });
}

const _remoteDocument = DocumentRecord(
  id: 1,
  title: '销售出库',
  number: 'SO-20260626-001',
  status: '待提交',
  productName: '矿泉水 550ml',
  quantity: 3,
);

final class _FakeDocumentsRepository implements DocumentsRepository {
  _FakeDocumentsRepository({
    this.listResult = const Success<List<DocumentRecord>>([_remoteDocument]),
    this.createResult = const Success<DocumentRecord>(_remoteDocument),
  });

  final Result<List<DocumentRecord>> listResult;
  final Result<DocumentRecord> createResult;
  CreateDocumentRequest? createdRequest;

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments() async {
    return listResult;
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    createdRequest = request;
    return createResult;
  }
}
