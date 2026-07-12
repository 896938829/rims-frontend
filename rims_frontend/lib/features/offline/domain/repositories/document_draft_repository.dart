import '../../../../core/result/result.dart';
import '../entities/document_draft.dart';

abstract interface class DocumentDraftRepository {
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  });

  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  });

  Future<List<DocumentDraft>> list(String accountId);

  Future<void> delete({required String accountId, required String draftId});

  Future<void> prune();
}
