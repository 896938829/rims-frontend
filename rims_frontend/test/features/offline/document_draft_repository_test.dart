import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_document_draft_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);

  test(
    'persists all six document intents without stock authorization',
    () async {
      final repository = DriftDocumentDraftRepository(
        store: MemoryOfflineStore(),
        now: () => now,
      );
      for (var docType = 1; docType <= 6; docType += 1) {
        final result = await repository.save(
          _draft(
            id: 'draft-$docType',
            docType: docType,
            payload: {
              'lines': [
                {'product_id': 10, 'quantity': docType == 5 ? 0 : 2},
              ],
              if (docType == 4) 'target_warehouse_id': 12,
              if (docType == 3) 'source_document_id': 91,
              if (docType == 6) 'non_standard_source_id': 31,
            },
            attachmentIds: ['staged-$docType'],
          ),
          expectedVersion: 0,
        );

        final saved = _success(result);
        expect(saved.docType, docType);
        expect(saved.version, 1);
        expect(saved.attachmentStagingIds, ['staged-$docType']);
        expect(saved.payload.toString(), isNot(contains('stockQuantity')));
        if (docType == 5) {
          final lines = saved.payload['lines']! as List;
          expect((lines.single as Map)['quantity'], 0);
        }
      }
    },
  );

  test('rejects cached stock authority fields', () async {
    final repository = DriftDocumentDraftRepository(
      store: MemoryOfflineStore(),
    );

    final result = await repository.save(
      _draft(
        id: 'unsafe',
        docType: 2,
        payload: const {'availableQuantity': 99},
      ),
      expectedVersion: 0,
    );

    expect(result, isA<FailureResult<DocumentDraft>>());
    expect(
      (result as FailureResult<DocumentDraft>).failure,
      isA<StateFailure>(),
    );
  });

  test(
    'isolates account and marks stale role or warehouse for review',
    () async {
      final repository = DriftDocumentDraftRepository(
        store: MemoryOfflineStore(),
        now: () => now,
      );
      await repository.save(
        _draft(id: 'owned', docType: 2),
        expectedVersion: 0,
      );

      expect(await repository.load(accountId: '8', draftId: 'owned'), isNull);
      final loaded = await repository.load(accountId: '7', draftId: 'owned');

      expect(
        loaded!.reviewAgainst(roleCode: 'admin', warehouseId: 12).reasons,
        containsAll([
          DraftReviewReason.roleChanged,
          DraftReviewReason.warehouseChanged,
        ]),
      );
    },
  );

  test('optimistic version rejects stale concurrent save', () async {
    final repository = DriftDocumentDraftRepository(
      store: MemoryOfflineStore(),
      now: () => now,
    );
    final first = _success(
      await repository.save(
        _draft(id: 'versioned', docType: 1),
        expectedVersion: 0,
      ),
    );
    expect(first.version, 1);

    final stale = await repository.save(first, expectedVersion: 0);

    expect(stale, isA<FailureResult<DocumentDraft>>());
    expect(
      (stale as FailureResult<DocumentDraft>).failure,
      isA<ConflictFailure>(),
    );
  });

  test('prunes drafts older than retention but keeps boundary', () async {
    final store = MemoryOfflineStore();
    final repository = DriftDocumentDraftRepository(
      store: store,
      now: () => now,
    );
    await store.saveDraft(
      _draft(
        id: 'expired',
        docType: 1,
        updatedAt: now.subtract(const Duration(days: 31)),
      ),
    );
    await store.saveDraft(
      _draft(
        id: 'boundary',
        docType: 1,
        updatedAt: now.subtract(const Duration(days: 30)),
      ),
    );

    await repository.prune();

    expect((await repository.list('7')).map((draft) => draft.id), ['boundary']);
  });

  test('migrates legacy schema zero payload on read', () async {
    final store = MemoryOfflineStore();
    await store.saveDraft(
      _draft(
        id: 'legacy',
        docType: 2,
        schemaVersion: 0,
        payload: const {'productId': 10, 'quantity': 3},
      ),
    );
    final repository = DriftDocumentDraftRepository(
      store: store,
      now: () => now,
    );

    final migrated = await repository.load(accountId: '7', draftId: 'legacy');

    expect(migrated?.schemaVersion, 1);
    expect(migrated?.payload['lines'], [
      {'product_id': 10, 'quantity': 3},
    ]);
  });

  test('serializes immutable user-entered document intent', () {
    final payload = const CreateDocumentRequest(
      docType: 6,
      typeLabel: 'non-standard conversion',
      lines: [
        CreateDocumentLineRequest(
          productId: 10,
          productName: 'Product',
          quantity: 0,
          actualQuantity: 0,
          nonStandardInventoryId: 31,
          retailPrice: 12.5,
        ),
      ],
      toWarehouseId: 12,
      refDocId: 91,
      remark: 'keep intent only',
    ).toDraftPayload();

    expect(payload, {
      'lines': [
        {
          'product_id': 10,
          'product_name': 'Product',
          'quantity': 0,
          'actual_quantity': 0,
          'non_standard_inventory_id': 31,
          'retail_price': 12.5,
        },
      ],
      'target_warehouse_id': 12,
      'source_document_id': 91,
      'remark': 'keep intent only',
    });
    expect(() => payload['remark'] = 'changed', throwsUnsupportedError);
    expect(
      () => (payload['lines']! as List<Object?>).add(const {}),
      throwsUnsupportedError,
    );
  });

  test('draft snapshots nested payload and attachment collections', () {
    final line = <String, Object?>{'product_id': 10, 'quantity': 2};
    final lines = <Object?>[line];
    final payload = <String, Object?>{'lines': lines};
    final attachments = <String>['staged-1'];

    final draft = _draft(
      id: 'immutable',
      docType: 1,
      payload: payload,
      attachmentIds: attachments,
    );
    line['quantity'] = 99;
    lines.add(const {'product_id': 11});
    payload['remark'] = 'late mutation';
    attachments.add('staged-2');

    expect(draft.payload, {
      'lines': [
        {'product_id': 10, 'quantity': 2},
      ],
    });
    expect(draft.attachmentStagingIds, ['staged-1']);
    expect(
      () => (draft.payload['lines']! as List<Object?>).clear(),
      throwsUnsupportedError,
    );
  });
}

DocumentDraft _draft({
  required String id,
  required int docType,
  Map<String, Object?> payload = const {},
  List<String> attachmentIds = const [],
  int schemaVersion = 1,
  DateTime? updatedAt,
}) {
  final created = DateTime.utc(2026, 7, 1);
  return DocumentDraft(
    id: id,
    accountId: '7',
    warehouseId: 11,
    docType: docType,
    observedRoleCode: 'user',
    payload: payload,
    attachmentStagingIds: attachmentIds,
    schemaVersion: schemaVersion,
    createdAt: created,
    updatedAt: updatedAt ?? created,
  );
}

T _success<T>(Result<T> result) => result.when(
  success: (value) => value,
  failure: (failure) => throw TestFailure('Expected success: $failure'),
);
