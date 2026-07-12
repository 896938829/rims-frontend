import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/document_draft.dart';
import '../../domain/repositories/document_draft_repository.dart';
import '../../domain/services/offline_store.dart';

final class DriftDocumentDraftRepository implements DocumentDraftRepository {
  DriftDocumentDraftRepository({
    required this.store,
    DateTime Function()? now,
    this.retention = const Duration(days: 30),
  }) : now = now ?? DateTime.now;

  final OfflineStore store;
  final DateTime Function() now;
  final Duration retention;

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
    if (draft.docType < 1 || draft.docType > 6) {
      return const FailureResult(
        ValidationFailure(message: 'Unsupported document draft type.'),
      );
    }
    if (_containsStockAuthority(draft.payload)) {
      return const FailureResult(
        StateFailure(message: 'Drafts cannot store cached stock authority.'),
      );
    }
    final saved = DocumentDraft(
      id: draft.id,
      accountId: draft.accountId,
      warehouseId: draft.warehouseId,
      docType: draft.docType,
      observedRoleCode: draft.observedRoleCode,
      payload: draft.payload,
      attachmentStagingIds: List.unmodifiable(draft.attachmentStagingIds),
      schemaVersion: 1,
      createdAt: draft.createdAt,
      updatedAt: now().toUtc(),
      version: expectedVersion + 1,
    );
    try {
      await store.saveDraft(saved, expectedVersion: expectedVersion);
      return Success(saved);
    } on StateError catch (error) {
      return FailureResult(ConflictFailure(message: error.message.toString()));
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to save document draft.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async {
    for (final draft in await store.listDrafts(accountId)) {
      if (draft.id == draftId) return _migrate(draft);
    }
    return null;
  }

  @override
  Future<List<DocumentDraft>> list(String accountId) async {
    return Future.wait((await store.listDrafts(accountId)).map(_migrate));
  }

  @override
  Future<void> delete({required String accountId, required String draftId}) {
    return store.deleteDraft(accountId: accountId, draftId: draftId);
  }

  @override
  Future<void> prune() {
    return store.pruneDrafts(now().toUtc().subtract(retention));
  }

  Future<DocumentDraft> _migrate(DocumentDraft draft) async {
    if (draft.schemaVersion >= 1) return draft;
    final payload = Map<String, Object?>.from(draft.payload);
    if (!payload.containsKey('lines') &&
        payload['productId'] is int &&
        payload['quantity'] is int) {
      payload['lines'] = [
        {
          'product_id': payload.remove('productId'),
          'quantity': payload.remove('quantity'),
        },
      ];
    }
    final migrated = draft.copyWith(payload: payload, schemaVersion: 1);
    await store.saveDraft(migrated);
    return migrated;
  }

  bool _containsStockAuthority(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().replaceAll('_', '').toLowerCase();
        if (key == 'availablequantity' ||
            key == 'stockquantity' ||
            key == 'beforeqty' ||
            key == 'afterqty') {
          return true;
        }
        if (_containsStockAuthority(entry.value)) return true;
      }
    } else if (value is List) {
      return value.any(_containsStockAuthority);
    }
    return false;
  }
}
