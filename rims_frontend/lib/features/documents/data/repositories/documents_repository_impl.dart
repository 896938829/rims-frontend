import '../../../../core/result/result.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../datasources/documents_remote_datasource.dart';

final class DocumentsRepositoryImpl implements DocumentsRepository {
  const DocumentsRepositoryImpl({required this.remoteDataSource});

  final DocumentsRemoteDataSource remoteDataSource;

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    final result = await remoteDataSource.listRecentDocuments(
      docType: docType,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<DocumentRecord>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<DocumentRecord>>.new,
    );
  }

  @override
  Future<Result<List<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listTransactions(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<TransactionRecord>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<TransactionRecord>>.new,
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
