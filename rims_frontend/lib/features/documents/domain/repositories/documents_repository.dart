import '../../../../core/result/result.dart';
import '../entities/document_data.dart';

abstract interface class DocumentsRepository {
  Future<Result<List<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  });

  Future<Result<List<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  });

  Future<Result<DocumentRecord>> createDocument(CreateDocumentRequest request);

  Future<Result<void>> completeDocument(int id);

  Future<Result<void>> confirmDocument(int id);

  Future<Result<void>> settleDocument(int id);
}
