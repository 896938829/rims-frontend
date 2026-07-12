import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../datasources/documents_remote_datasource.dart';

final class DocumentsRepositoryImpl
    implements DocumentsRepository, DocumentDetailsRepository {
  const DocumentsRepositoryImpl({required this.remoteDataSource});

  final DocumentsRemoteDataSource remoteDataSource;

  @override
  Future<Result<DocumentDetail>> getDocument(int id) async {
    final result = await remoteDataSource.getDocument(id);
    return result.when(
      success: (model) => Success(model.toEntity()),
      failure: FailureResult<DocumentDetail>.new,
    );
  }

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    final result = await remoteDataSource.listRecentDocuments(
      docType: docType,
      page: page,
    );

    return result.when(
      success: (page) => Success<PageData<DocumentRecord>>(
        page.map((model) => model.toEntity()),
      ),
      failure: FailureResult<PageData<DocumentRecord>>.new,
    );
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listTransactions(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (page) => Success<PageData<TransactionRecord>>(
        page.map((model) => model.toEntity()),
      ),
      failure: FailureResult<PageData<TransactionRecord>>.new,
    );
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    final result = await remoteDataSource.createDocument(request);

    return result.when(
      success: (model) => Success<DocumentRecord>(model.toEntity()),
      failure: FailureResult<DocumentRecord>.new,
    );
  }

  @override
  Future<Result<void>> completeDocument(int id) {
    return remoteDataSource.completeDocument(id);
  }

  @override
  Future<Result<void>> confirmDocument(int id) {
    return remoteDataSource.confirmDocument(id);
  }

  @override
  Future<Result<void>> settleDocument(int id) {
    return remoteDataSource.settleDocument(id);
  }
}
