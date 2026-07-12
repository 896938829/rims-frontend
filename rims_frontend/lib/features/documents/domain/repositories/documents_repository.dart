import '../../../../core/result/result.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/pagination/page_data.dart';
import '../entities/document_data.dart';

abstract interface class DocumentsRepository {
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  });

  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  });

  Future<Result<DocumentRecord>> createDocument(CreateDocumentRequest request);

  Future<Result<void>> completeDocument(int id);

  Future<Result<void>> confirmDocument(int id);

  Future<Result<void>> settleDocument(int id);
}

abstract interface class DocumentDetailsRepository {
  Future<Result<DocumentDetail>> getDocument(int id);
}

Future<Result<DocumentDetail>> getDocumentDetails(
  DocumentsRepository repository,
  int id,
) {
  if (repository case final DocumentDetailsRepository detailsRepository) {
    return detailsRepository.getDocument(id);
  }
  return Future.value(
    const FailureResult(
      UnknownFailure(message: 'Document details are unavailable.'),
    ),
  );
}
