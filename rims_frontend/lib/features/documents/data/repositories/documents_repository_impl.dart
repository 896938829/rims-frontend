import '../../../../core/result/result.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../datasources/documents_remote_datasource.dart';

final class DocumentsRepositoryImpl implements DocumentsRepository {
  const DocumentsRepositoryImpl({required this.remoteDataSource});

  final DocumentsRemoteDataSource remoteDataSource;

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments() async {
    final result = await remoteDataSource.listRecentDocuments();

    return result.when(
      success: (models) => Success<List<DocumentRecord>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<DocumentRecord>>.new,
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
}
