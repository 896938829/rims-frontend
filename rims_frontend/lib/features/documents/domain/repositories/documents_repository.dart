import '../../../../core/result/result.dart';
import '../entities/document_data.dart';

abstract interface class DocumentsRepository {
  Future<Result<List<DocumentRecord>>> listRecentDocuments();

  Future<Result<DocumentRecord>> createDocument(CreateDocumentRequest request);
}
