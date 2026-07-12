import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/documents/presentation/pages/documents_page.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_documents_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';

void main() {
  var warehouseId = 11;
  final now = DateTime.utc(2026, 7, 13, 12);
  late _FakeDocumentsRepository delegate;
  late CachedDocumentsRepository repository;

  setUp(() {
    warehouseId = 11;
    delegate = _FakeDocumentsRepository();
    repository = CachedDocumentsRepository(
      delegate: delegate,
      store: MemoryOfflineStore(),
      accountIdReader: () => '7',
      warehouseIdReader: () => warehouseId,
      now: () => now,
    );
  });

  test('recent page and selected detail fall back with source age', () async {
    delegate.recentResult = Success(_page([_record]));
    delegate.detailResult = Success(_detail);
    await repository.listRecentDocuments(docType: 2);
    await repository.getDocument(9);
    delegate.recentResult = const FailureResult(NetworkFailure());
    delegate.detailResult = const FailureResult(NetworkFailure());

    expect(
      _pageFrom(
        await repository.listRecentDocuments(docType: 2),
      ).items.single.id,
      9,
    );
    expect((await repository.getDocument(9)).isSuccess, isTrue);
    expect(repository.lastReadStatus?.source, DocumentDataSource.cache);
    expect(repository.lastReadStatus?.fetchedAt, now);
  });

  test('document query and warehouse scopes never cross', () async {
    delegate.recentResult = Success(_page([_record]));
    await repository.listRecentDocuments(docType: 2, page: 1);
    delegate.recentResult = const FailureResult(NetworkFailure());

    expect(
      await repository.listRecentDocuments(docType: 1, page: 1),
      isA<FailureResult>(),
    );
    warehouseId = 12;
    expect(
      await repository.listRecentDocuments(docType: 2, page: 1),
      isA<FailureResult>(),
    );
  });

  test('transactions and business failures never use cache', () async {
    delegate.recentResult = Success(_page([_record]));
    await repository.listRecentDocuments();
    delegate.recentResult = const FailureResult(AuthorizationFailure());
    expect(await repository.listRecentDocuments(), isA<FailureResult>());

    delegate.transactionsResult = const FailureResult(NetworkFailure());
    expect(await repository.listTransactions(), isA<FailureResult>());
  });

  testWidgets('documents page renders cached source and update time', (
    tester,
  ) async {
    delegate.recentResult = Success(_page([_record]));
    await repository.listRecentDocuments();
    delegate.recentResult = const FailureResult(NetworkFailure());
    delegate.transactionsResult = Success(
      PageData(items: const [], total: 0, page: 1, pageSize: 10),
    );
    final viewModel = DocumentsViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('documents-cache-status')), findsOneWidget);
    expect(find.textContaining('离线缓存 · 更新于'), findsOneWidget);
  });
}

PageData<DocumentRecord> _page(List<DocumentRecord> items) =>
    PageData(items: items, total: items.length, page: 1, pageSize: 10);
PageData<DocumentRecord> _pageFrom(Result<PageData<DocumentRecord>> result) =>
    result.when(
      success: (value) => value,
      failure: (failure) => throw TestFailure('Expected page: $failure'),
    );

const _record = DocumentRecord(
  id: 9,
  docType: 2,
  title: '销售单',
  number: 'XS-9',
  status: '已完成',
  productName: 'Water',
  quantity: 2,
  remark: 'ok',
  createdAt: '2026-07-13T10:00:00Z',
);
final _detail = DocumentDetail(
  record: _record,
  lines: const [
    DocumentLine(
      id: 1,
      productId: 5,
      nonStandardInventoryId: 0,
      productCode: 'SKU-5',
      productName: 'Water',
      quantity: 2,
      unit: '件',
      costPrice: 1,
      retailPrice: 2,
      systemQuantity: 3,
      actualQuantity: 3,
      differenceQuantity: 0,
      remark: '',
    ),
  ],
);

final class _FakeDocumentsRepository
    implements DocumentsRepository, DocumentDetailsRepository {
  Result<PageData<DocumentRecord>> recentResult = const FailureResult(
    UnknownFailure(),
  );
  Result<PageData<TransactionRecord>> transactionsResult = const FailureResult(
    UnknownFailure(),
  );
  Result<DocumentDetail> detailResult = const FailureResult(UnknownFailure());

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async => recentResult;

  @override
  Future<Result<DocumentDetail>> getDocument(int id) async => detailResult;

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async => transactionsResult;

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) => throw UnimplementedError();
  @override
  Future<Result<void>> completeDocument(int id) => throw UnimplementedError();
  @override
  Future<Result<void>> confirmDocument(int id) => throw UnimplementedError();
  @override
  Future<Result<void>> settleDocument(int id) => throw UnimplementedError();
}
