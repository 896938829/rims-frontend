import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/documents/presentation/pages/documents_page.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';

void main() {
  testWidgets(
    'document and transaction pagination controls fail independently',
    (tester) async {
      final repository = _PageRepository(
        documents: [
          Success(_documents([_document], total: 11)),
          const FailureResult(NetworkFailure(message: 'document next failed')),
        ],
        transactions: [
          Success(_transactions([_transaction], total: 11)),
          const FailureResult(
            NetworkFailure(message: 'transaction next failed'),
          ),
        ],
      );
      final viewModel = DocumentsViewModel(repository: repository);
      await viewModel.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
        ),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('documents-load-more-button')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const Key('documents-load-more-button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('documents-load-more-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('documents-load-more-retry')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('transactions-load-more-button')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const Key('transactions-load-more-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('transactions-load-more-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('transactions-load-more-retry')),
        findsOneWidget,
      );
    },
  );

  testWidgets('both completed streams expose their own end indicator', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel(
      repository: _PageRepository(
        documents: [
          Success(_documents([_document])),
        ],
        transactions: [
          Success(_transactions([_transaction])),
        ],
      ),
    );
    await viewModel.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('documents-page-end')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('documents-page-end')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('transactions-page-end')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('transactions-page-end')), findsOneWidget);
  });
}

PageData<DocumentRecord> _documents(List<DocumentRecord> items, {int? total}) =>
    PageData(items: items, total: total ?? items.length, page: 1, pageSize: 10);

PageData<TransactionRecord> _transactions(
  List<TransactionRecord> items, {
  int? total,
}) =>
    PageData(items: items, total: total ?? items.length, page: 1, pageSize: 10);

const _document = DocumentRecord(
  id: 1,
  docType: 2,
  title: '销售出库',
  number: 'M9DOC0001',
  status: '已完成',
);

const _transaction = TransactionRecord(
  id: 1,
  warehouseId: 1,
  productId: 1,
  docId: 1,
  docNo: 'M9DOC0001',
  docType: 2,
  docTypeName: '销售单',
  direction: -1,
  quantity: 1,
  beforeQty: 2,
  afterQty: 1,
  operatorId: 1,
  operatedAt: '2026-07-11T00:00:00Z',
  createdAt: '2026-07-11T00:00:00Z',
);

final class _PageRepository implements DocumentsRepository {
  _PageRepository({required this.documents, required this.transactions});
  final List<Result<PageData<DocumentRecord>>> documents;
  final List<Result<PageData<TransactionRecord>>> transactions;
  int _documentIndex = 0;
  int _transactionIndex = 0;

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async => documents[_documentIndex++];

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async => transactions[_transactionIndex++];

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async => const Success(_document);
  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async =>
      const Success(null);
  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async =>
      const Success(null);
  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async =>
      const Success(null);
}
