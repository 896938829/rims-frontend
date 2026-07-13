import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/documents/data/datasources/documents_remote_datasource.dart';
import 'package:rims_frontend/features/documents/data/repositories/documents_repository_impl.dart';
import 'package:rims_frontend/features/documents/presentation/pages/documents_page.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_document_draft_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation_output.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/idempotency_key_validator.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  test(
    'document changes debounce autosave for 300ms with a stable draft id',
    () async {
      final drafts = _FakeDocumentDraftRepository();
      final viewModel = DocumentsViewModel(
        draftRepository: drafts,
        accountId: '7',
        observedRoleCode: 'operator',
        currentWarehouse: const Warehouse(
          id: 11,
          code: 'MAIN',
          name: 'Main',
          isDefault: true,
        ),
        draftIdFactory: () => 'draft-stable',
      );

      viewModel.updateRemark('first');
      viewModel.updateRemark('latest');

      expect(viewModel.activeDraftId, 'draft-stable');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(drafts.saved, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(drafts.saved, hasLength(1));
      expect(drafts.saved.single.id, 'draft-stable');
      expect(drafts.saved.single.payload['remark'], 'latest');
      viewModel.dispose();
    },
  );

  test(
    'explicit save flushes immediately and autosave remains one-flight',
    () async {
      final firstSave = Completer<Result<DocumentDraft>>();
      final drafts = _FakeDocumentDraftRepository(
        saveResults: [firstSave.future],
      );
      final viewModel = DocumentsViewModel(
        draftRepository: drafts,
        accountId: '7',
        observedRoleCode: 'operator',
        currentWarehouse: const Warehouse(
          id: 11,
          code: 'MAIN',
          name: 'Main',
          isDefault: true,
        ),
        draftIdFactory: () => 'draft-one-flight',
      );

      viewModel.updateRemark('first');
      final save = viewModel.saveDraft();
      await Future<void>.delayed(Duration.zero);
      viewModel.updateRemark('second');
      await Future<void>.delayed(const Duration(milliseconds: 320));
      expect(drafts.saveCallCount, 1);

      firstSave.complete(
        Success(_savedDraft('draft-one-flight', remark: 'first')),
      );
      await save;
      await Future<void>.delayed(Duration.zero);

      expect(drafts.saveCallCount, 2);
      expect(drafts.saved.last.payload['remark'], 'second');
      viewModel.dispose();
    },
  );

  test(
    'autosave failure stays visible and preserves the in-memory form',
    () async {
      final drafts = _FakeDocumentDraftRepository(
        saveResults: [
          Future.value(
            const FailureResult<DocumentDraft>(
              LocalStorageFailure(message: '草稿保存失败'),
            ),
          ),
        ],
      );
      final viewModel = DocumentsViewModel(
        draftRepository: drafts,
        accountId: '7',
        observedRoleCode: 'operator',
        currentWarehouse: const Warehouse(
          id: 11,
          code: 'MAIN',
          name: 'Main',
          isDefault: true,
        ),
      );

      viewModel.addScannedProduct(_standardItem);
      viewModel.updateRemark('keep me');
      await viewModel.saveDraft();

      expect(viewModel.draftSaveError, '草稿保存失败');
      expect(viewModel.draftLines, isNotEmpty);
      expect(viewModel.remark, 'keep me');
      viewModel.dispose();
    },
  );

  test('reopens a scoped draft into the document form', () async {
    final draft = _savedDraft('recoverable', remark: 'recovered');
    final drafts = _FakeDocumentDraftRepository(loaded: draft);
    final viewModel = DocumentsViewModel(
      draftRepository: drafts,
      accountId: '7',
      observedRoleCode: 'operator',
      currentWarehouse: const Warehouse(
        id: 11,
        code: 'MAIN',
        name: 'Main',
        isDefault: true,
      ),
    );

    expect(await viewModel.openDraft('recoverable'), isTrue);

    expect(viewModel.activeDraftId, 'recoverable');
    expect(viewModel.remark, 'recovered');
    expect(viewModel.draftLines.single.productId, 10);
    expect(viewModel.draftLines.single.quantity, 2);
    viewModel.dispose();
  });

  test('operator cannot open or submit an old admin document draft', () async {
    for (final docType in [4, 6]) {
      final draft = _savedDraft(
        'admin-$docType',
        docType: docType,
        observedRoleCode: 'admin',
      );
      final documents = _FakeDocumentsRepository();
      final viewModel = DocumentsViewModel(
        repository: documents,
        draftRepository: _FakeDocumentDraftRepository(loaded: draft),
        accountId: '7',
        observedRoleCode: 'operator',
        canManageAdminDocumentActions: false,
        currentWarehouse: const Warehouse(
          id: 11,
          code: 'MAIN',
          name: 'Main',
          isDefault: true,
        ),
      );

      expect(await viewModel.openDraft(draft.id), isFalse);
      expect(viewModel.activeDraftId, isNull);
      expect(viewModel.draftSaveError, '当前账号无权使用该单据类型');
      expect(await viewModel.createDocument(), isFalse);
      expect(documents.createCallCount, 0);
      viewModel.dispose();
    }
  });

  test('late save for draft A cannot update draft B save identity', () async {
    final drafts = _ControlledDraftRepository()
      ..seed(_savedDraft('draft-b', remark: 'draft B'));
    final viewModel = _draftEnabledViewModel(
      drafts: drafts,
      draftIdFactory: () => 'draft-a',
    );
    viewModel.updateRemark('draft A');
    final saveA = viewModel.saveDraft();
    await _waitFor(() => drafts.saveCallCount == 1);

    expect(await viewModel.openDraft('draft-b'), isTrue);
    drafts.completeNextSave(version: 99);
    await saveA;
    viewModel.updateRemark('draft B changed');
    final saveB = viewModel.saveDraft();
    await _waitFor(() => drafts.saveCallCount == 2);

    expect(drafts.pendingDraftIds.single, 'draft-b');
    expect(drafts.pendingExpectedVersions.single, 1);
    drafts.completeNextSave();
    await saveB;
    viewModel.dispose();
  });

  test('only the latest concurrent openDraft request can apply', () async {
    final drafts = _OutOfOrderOpenDraftRepository();
    final viewModel = _draftEnabledViewModel(drafts: drafts);

    final openA = viewModel.openDraft('draft-a');
    final openB = viewModel.openDraft('draft-b');
    drafts.complete('draft-b', _savedDraft('draft-b', remark: 'draft B'));
    expect(await openB, isTrue);
    drafts.complete('draft-a', _savedDraft('draft-a', remark: 'draft A'));

    expect(await openA, isFalse);
    expect(viewModel.activeDraftId, 'draft-b');
    expect(viewModel.remark, 'draft B');
    viewModel.dispose();
  });

  test('stale openDraft failure cannot overwrite the latest success', () async {
    final drafts = _OutOfOrderOpenDraftRepository();
    final viewModel = _draftEnabledViewModel(drafts: drafts);

    final openMissing = viewModel.openDraft('missing-a');
    final openB = viewModel.openDraft('draft-b');
    drafts.complete('draft-b', _savedDraft('draft-b', remark: 'draft B'));
    expect(await openB, isTrue);
    drafts.complete('missing-a', null);

    expect(await openMissing, isFalse);
    expect(viewModel.activeDraftId, 'draft-b');
    expect(viewModel.draftSaveError, isNull);
    viewModel.dispose();
  });

  test('successful submit deletes only the active account draft', () async {
    final drafts = _FakeDocumentDraftRepository();
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
      draftRepository: drafts,
      accountId: '7',
      observedRoleCode: 'operator',
      currentWarehouse: const Warehouse(
        id: 11,
        code: 'MAIN',
        name: 'Main',
        isDefault: true,
      ),
      draftIdFactory: () => 'submitted-draft',
    );
    viewModel.addScannedProduct(_standardItem);
    await viewModel.saveDraft();

    expect(await viewModel.createDocument(), isTrue);

    expect(drafts.deleted, [('7', 'submitted-draft')]);
    expect(viewModel.activeDraftId, isNull);
    viewModel.dispose();
  });

  test(
    'draft save and reopen preserve staged attachment request ids',
    () async {
      final drafts = _FakeDocumentDraftRepository();
      final viewModel = _draftEnabledViewModel(
        drafts: drafts,
        draftIdFactory: () => 'draft-attachments',
      );

      expect(viewModel.ensureDraftId(), 'draft-attachments');
      viewModel.updateAttachmentStagingIds(['staged-a', 'staged-b']);
      await viewModel.saveDraft();

      expect(drafts.saved.single.attachmentStagingIds, [
        'staged-a',
        'staged-b',
      ]);
      final reopened = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(loaded: drafts.saved.single),
      );
      expect(await reopened.openDraft('draft-attachments'), isTrue);
      expect(reopened.attachmentStagingIds, ['staged-a', 'staged-b']);
    },
  );

  test(
    'submit drains queued saves before delete and cannot recreate draft',
    () async {
      final drafts = _ControlledDraftRepository();
      final viewModel = _draftEnabledViewModel(
        drafts: drafts,
        documents: _FakeDocumentsRepository(),
        draftIdFactory: () => 'submit-barrier',
      );
      viewModel.addScannedProduct(_standardItem);
      final firstSave = viewModel.saveDraft();
      await Future<void>.delayed(Duration.zero);
      viewModel.updateRemark('queued-latest');
      await Future<void>.delayed(const Duration(milliseconds: 320));

      final submit = viewModel.createDocument();
      drafts.completeNextSave();
      await _waitFor(() => drafts.saveCallCount == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drafts.deleted, isEmpty);
      drafts.completeNextSave();
      await firstSave;
      expect(await submit, isTrue);

      expect(drafts.deleted, [('7', 'submit-barrier')]);
      expect(drafts.persistedDraftIds, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(drafts.persistedDraftIds, isEmpty);
    },
  );

  test(
    'conversion source id saves, reopens, revalidates, and submits',
    () async {
      final drafts = _FakeDocumentDraftRepository();
      final writer =
          _draftEnabledViewModel(
              drafts: drafts,
              inventory: _FakeInventoryRepository(),
            )
            ..selectActionByLabel('转标准')
            ..selectNonStandardInventory(_nonStandardItem)
            ..addProductToDraft(_standardItem, quantity: 2);
      await writer.saveDraft();
      expect(drafts.saved.single.payload['non_standard_source_id'], 11);

      final documents = _FakeDocumentsRepository();
      final reader = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(loaded: drafts.saved.single),
        documents: documents,
        inventory: _FakeInventoryRepository(),
      );
      expect(await reader.openDraft(drafts.saved.single.id), isTrue);
      expect(reader.nonStandardSourceId, 11);
      expect(await reader.createDocument(), isTrue);
      expect(documents.createdRequest?.nonStdInventoryId, 11);
    },
  );

  test('role-changed draft requires explicit review before submit', () async {
    final oldRoleDraft = _savedDraft('role-review').copyWith();
    final repository = _FakeDocumentsRepository();
    final viewModel = _draftEnabledViewModel(
      drafts: _FakeDocumentDraftRepository(loaded: oldRoleDraft),
      documents: repository,
      roleCode: 'admin',
    );

    expect(await viewModel.openDraft('role-review'), isTrue);
    expect(viewModel.requiresDraftReview, isTrue);
    expect(await viewModel.createDocument(), isFalse);
    expect(repository.createCallCount, 0);

    viewModel.confirmDraftReview();
    expect(viewModel.requiresDraftReview, isFalse);
    expect(await viewModel.createDocument(), isTrue);
  });

  test(
    'pending product query, selection, and quantity recover before line add',
    () async {
      final drafts = _FakeDocumentDraftRepository();
      final writer = _draftEnabledViewModel(drafts: drafts);
      writer.updateProductName('矿泉');
      writer.selectProduct(_standardItem);
      writer.updateQuantity('7');
      await writer.saveDraft();

      final reader = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(loaded: drafts.saved.single),
      );
      expect(await reader.openDraft(drafts.saved.single.id), isTrue);

      expect(reader.productQuery, _standardItem.productName);
      expect(reader.selectedProduct?.productId, _standardItem.productId);
      expect(reader.quantityText, '7');
    },
  );

  test(
    'real repository and store recover a draft after process rebuild',
    () async {
      final store = MemoryOfflineStore();
      final writer = _draftEnabledViewModel(
        drafts: DriftDocumentDraftRepository(store: store),
        draftIdFactory: () => 'process-draft',
      );
      writer.selectProduct(_standardItem);
      writer.updateQuantity('4');
      writer.updateAttachmentStagingIds(['persisted-file']);
      await writer.saveDraft();
      writer.dispose();

      final rebuilt = _draftEnabledViewModel(
        drafts: DriftDocumentDraftRepository(store: store),
      );
      expect(await rebuilt.openDraft('process-draft'), isTrue);
      expect(rebuilt.selectedProduct?.productId, 10);
      expect(rebuilt.quantityText, '4');
      expect(rebuilt.attachmentStagingIds, ['persisted-file']);
    },
  );

  testWidgets('new document form stages attachments against stable draft id', (
    tester,
  ) async {
    final drafts = _FakeDocumentDraftRepository();
    final staging = _PageDraftStaging();
    final viewModel = _draftEnabledViewModel(
      drafts: drafts,
      draftIdFactory: () => 'ui-stable-draft',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(
            viewModel: viewModel,
            attachmentPicker: _PageDraftPicker(),
            attachmentStagingStore: staging,
            attachmentUserId: '7',
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('document-draft-attachment-file')));
    await tester.pumpAndSettle();

    expect(staging.bindings.single.localDraftId, 'ui-stable-draft');
    expect(viewModel.attachmentStagingIds, ['ui-request']);
  });

  testWidgets('role-changed form shows compact review confirmation', (
    tester,
  ) async {
    final draft = _savedDraft('ui-role-review');
    final viewModel = _draftEnabledViewModel(
      drafts: _FakeDocumentDraftRepository(loaded: draft),
      roleCode: 'admin',
    );
    await viewModel.openDraft(draft.id);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    expect(
      find.byKey(const Key('document-confirm-draft-review')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('document-confirm-draft-review')));
    await tester.pump();

    expect(viewModel.requiresDraftReview, isFalse);
    viewModel.dispose();
  });

  test(
    'DocumentsViewModel ignores an async load completion after dispose',
    () async {
      final repository = _RetryDocumentsRepository();
      final viewModel = DocumentsViewModel(repository: repository);
      await viewModel.load();

      final loadFuture = viewModel.load();
      viewModel.dispose();
      repository.completeRetryDocuments();

      await expectLater(loadFuture, completes);
      expect(repository.transactionCallCount, 1);
      expect(viewModel.recentDocuments, isEmpty);
      expect(viewModel.notifyListeners, throwsFlutterError);
    },
  );

  test('load exposes document actions and backend recent documents', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.actions.map((action) => action.label), [
      '销售出库',
      '采购入库',
      '调拨单',
      '退货入库',
      '盘点单',
      '转标准',
    ]);
    expect(viewModel.flowSteps, ['创建', '确认', '提交', '完成']);
    expect(viewModel.recentDocuments, [_remoteDocument]);
    expect(viewModel.transactions, [_transactionRecord]);
    expect(viewModel.actions.first.label, '销售出库');
  });

  test('DocumentsViewModel selects document action', () {
    final viewModel = DocumentsViewModel();

    viewModel.selectActionByLabel('采购入库');

    expect(viewModel.selectedAction.label, '采购入库');
  });

  test(
    'scan-driven draft accumulates duplicates and submits one multi-line request',
    () async {
      final repository = _FakeDocumentsRepository();
      final viewModel = DocumentsViewModel(repository: repository);

      viewModel.addScannedProduct(_standardItem);
      viewModel.addScannedProduct(_standardItem);
      viewModel.addProductToDraft(_staleItem, quantity: 3);

      expect(viewModel.draftLines, hasLength(2));
      expect(viewModel.draftLines.first.quantity, 2);
      expect(await viewModel.createDocument(), isTrue);
      expect(repository.createCallCount, 1);
      expect(repository.createdRequest?.lines, hasLength(2));
      expect(repository.createdRequest?.lines.last.quantity, 3);
      expect(viewModel.draftLines, isEmpty);
    },
  );

  test(
    'failed multi-line submit retries with the same idempotency key',
    () async {
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(
          const FailureResult(NetworkFailure(message: '暂时离线')),
        ),
      );
      final viewModel = DocumentsViewModel(repository: repository);
      viewModel.addScannedProduct(_standardItem);

      expect(await viewModel.createDocument(), isFalse);
      expect(await viewModel.createDocument(), isFalse);

      expect(repository.createdRequestIds, hasLength(2));
      expect(repository.createdRequestIds.toSet(), hasLength(1));
      expect(viewModel.draftLines, isNotEmpty);
    },
  );

  test(
    'offline submit waits for explicit reviewed confirmation before enqueue',
    () async {
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(
          const FailureResult(NetworkFailure(message: '暂时离线')),
        ),
      );
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final staging = _OutboxSubmissionStagingStore();
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: repository,
        outbox: outbox,
        submissionStagingStore: staging,
        draftIdFactory: () => 'draft-1',
      );
      viewModel.addScannedProduct(_standardItem);
      viewModel.updateAttachmentStagingIds(const [
        'attachment-request-1',
        'attachment-request-2',
      ]);

      expect(await viewModel.createDocument(), isFalse);
      expect((await outbox.list('7')).successData, isEmpty);
      expect(viewModel.offlineSubmissionReview?.warehouseName, 'Main');
      expect(viewModel.offlineSubmissionReview?.documentType, '销售出库');
      expect(viewModel.offlineSubmissionReview?.lineCount, 1);
      expect(
        viewModel.offlineSubmissionReview?.staleAssumptions,
        contains(contains('创建并完成')),
      );

      expect(await viewModel.confirmOfflineSubmission(), isTrue);
      final queued = (await outbox.list('7')).successData;
      expect(queued.map((item) => item.kind), [
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.attachmentUpload,
        OutboxOperationKind.attachmentUpload,
        OutboxOperationKind.documentComplete,
      ]);
      expect(queued.first.idempotencyKey, repository.createdRequestIds.single);
      expect(
        queued.every(
          (operation) =>
              IdempotencyKeyValidator.isValid(operation.idempotencyKey),
        ),
        isTrue,
      );
      expect(queued.first.payload.toString(), isNot(contains('token')));
      expect(queued.first.payload.toString(), isNot(contains('cached')));
      expect(
        queued.take(3).every((item) => !item.payload.containsKey('cleanup')),
        isTrue,
      );
      expect(queued.last.payload['cleanup'], {
        'draftId': 'draft-1',
        'attachmentRequestIds': [
          'attachment-request-1',
          'attachment-request-2',
        ],
      });

      await outbox.confirm(
        accountId: '7',
        operationId: queued.first.operationId,
      );
      final initiallyReady = (await outbox.ready('7')).successData;
      expect(initiallyReady.map((item) => item.kind), [
        OutboxOperationKind.documentCreate,
      ]);
      await outbox.transition(
        accountId: '7',
        operationId: queued.first.operationId,
        next: OutboxState.syncing,
      );
      await outbox.completeSuccess(
        accountId: '7',
        operationId: queued.first.operationId,
        output: OutboxOperationOutput(version: 1, data: {'documentId': 91}),
      );
      for (var index = 1; index < queued.length; index += 1) {
        await outbox.confirm(
          accountId: '7',
          operationId: queued[index].operationId,
        );
        expect(
          (await outbox.ready('7')).successData.map((item) => item.operationId),
          [queued[index].operationId],
        );
        if (index < queued.length - 1) {
          await outbox.transition(
            accountId: '7',
            operationId: queued[index].operationId,
            next: OutboxState.syncing,
          );
          await outbox.completeSuccess(
            accountId: '7',
            operationId: queued[index].operationId,
            output: OutboxOperationOutput(
              version: 1,
              data: {'documentId': 91, 'attachmentId': 17},
            ),
          );
        }
      }
    },
  );

  test('offline graph permission is all or none before enqueue', () async {
    final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    final viewModel = _draftEnabledViewModel(
      drafts: _FakeDocumentDraftRepository(),
      documents: _FakeDocumentsRepository(
        createResult: Future.value(const FailureResult(NetworkFailure())),
      ),
      outbox: outbox,
      submissionStagingStore: _OutboxSubmissionStagingStore(),
      draftIdFactory: () => 'draft-1',
      allowedOutboxKinds: const {
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.attachmentUpload,
      },
    )..addScannedProduct(_standardItem);

    expect(await viewModel.createDocument(), isFalse);
    expect(
      viewModel.offlineSubmissionReview?.staleAssumptions,
      contains(contains('完整权限')),
    );
    expect(await viewModel.confirmOfflineSubmission(), isFalse);
    expect(viewModel.offlineSubmissionFailure, isA<AuthorizationFailure>());
    expect(viewModel.formError, contains('完成'));
    expect((await outbox.list('7')).successData, isEmpty);
  });

  test(
    'permission revoked after offline offer still prevents every graph write',
    () async {
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: _FakeDocumentsRepository(
          createResult: Future.value(const FailureResult(NetworkFailure())),
        ),
        outbox: outbox,
        submissionStagingStore: _OutboxSubmissionStagingStore(),
        draftIdFactory: () => 'draft-1',
      )..addScannedProduct(_standardItem);

      expect(await viewModel.createDocument(), isFalse);
      viewModel.updateAllowedOutboxKinds(const {
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.attachmentUpload,
      });

      expect(await viewModel.confirmOfflineSubmission(), isFalse);
      expect(viewModel.offlineSubmissionFailure, isA<AuthorizationFailure>());
      expect((await outbox.list('7')).successData, isEmpty);
    },
  );

  test('ordinary offline document types create then complete', () async {
    for (final action in const ['销售出库', '采购入库', '退货入库', '调拨单', '转标准']) {
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: _FakeDocumentsRepository(
          createResult: Future.value(const FailureResult(NetworkFailure())),
        ),
        inventory: _FakeInventoryRepository(),
        outbox: outbox,
        submissionStagingStore: _OutboxSubmissionStagingStore(),
        draftIdFactory: () => 'draft-1',
      )..selectActionByLabel(action);
      if (action == '退货入库') {
        viewModel.selectReturnSourceDocument(_completedSalesDocument);
      }
      if (action == '调拨单') {
        viewModel.selectTargetWarehouse(_beijingWarehouse);
      }
      if (action == '转标准') {
        viewModel.selectNonStandardInventory(_nonStandardItem);
      }
      viewModel.addProductToDraft(_standardItem, quantity: 1);

      expect(await viewModel.createDocument(), isFalse, reason: action);
      expect(
        await viewModel.confirmOfflineSubmission(),
        isTrue,
        reason: action,
      );

      final queued = (await outbox.list('7')).successData;
      expect(queued.map((operation) => operation.kind), [
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.documentComplete,
      ], reason: action);
      expect(queued.first.payload.containsKey('cleanup'), isFalse);
      expect(queued.last.payload.containsKey('cleanup'), isTrue);
      expect(
        queued.every(
          (operation) =>
              IdempotencyKeyValidator.isValid(operation.idempotencyKey),
        ),
        isTrue,
        reason: action,
      );
    }
  });

  test('offline stocktake serializes create confirm settle', () async {
    final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    final viewModel =
        _draftEnabledViewModel(
            drafts: _FakeDocumentDraftRepository(),
            documents: _FakeDocumentsRepository(
              createResult: Future.value(
                const FailureResult(TransportUnknownFailure()),
              ),
            ),
            outbox: outbox,
            submissionStagingStore: _OutboxSubmissionStagingStore(),
            draftIdFactory: () => 'draft-1',
          )
          ..selectActionByLabel('盘点单')
          ..addProductToDraft(_standardItem, quantity: 3);

    expect(await viewModel.createDocument(), isFalse);
    expect(
      viewModel.offlineSubmissionReview?.staleAssumptions,
      contains(contains('确认差异并结转')),
    );
    expect(await viewModel.confirmOfflineSubmission(), isTrue);

    final queued = (await outbox.list('7')).successData;
    expect(queued.map((operation) => operation.kind), [
      OutboxOperationKind.documentCreate,
      OutboxOperationKind.stocktakeConfirm,
      OutboxOperationKind.stocktakeSettle,
    ]);
    expect(queued.map((operation) => operation.requiresStatusProbe), [
      isTrue,
      isFalse,
      isFalse,
    ]);
    expect(
      queued.every(
        (operation) =>
            IdempotencyKeyValidator.isValid(operation.idempotencyKey),
      ),
      isTrue,
    );
    expect(
      queued.take(2).every((item) => !item.payload.containsKey('cleanup')),
      isTrue,
    );
    expect(queued.last.payload.containsKey('cleanup'), isTrue);
  });

  test(
    'repeated offline confirmation does not create a second write',
    () async {
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(const FailureResult(NetworkFailure())),
      );
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: repository,
        outbox: outbox,
        submissionStagingStore: _OutboxSubmissionStagingStore(),
        draftIdFactory: () => 'draft-1',
      );
      viewModel.addScannedProduct(_standardItem);

      await viewModel.createDocument();
      expect(await viewModel.confirmOfflineSubmission(), isTrue);
      expect(await viewModel.confirmOfflineSubmission(), isFalse);

      final queued = (await outbox.list('7')).successData;
      expect(queued, hasLength(2));
      expect(
        queued.first.operationId,
        'document-create-${queued.first.idempotencyKey}',
      );
      expect(queued.last.kind, OutboxOperationKind.documentComplete);
    },
  );

  test(
    'unknown result queues status-first while server validation never queues',
    () async {
      final unknownOutbox = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      final unknown = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: _FakeDocumentsRepository(
          createResult: Future.value(
            const FailureResult(TransportUnknownFailure()),
          ),
        ),
        outbox: unknownOutbox,
        submissionStagingStore: _OutboxSubmissionStagingStore(),
        draftIdFactory: () => 'draft-unknown',
      )..addScannedProduct(_standardItem);

      await unknown.createDocument();
      expect(await unknown.confirmOfflineSubmission(), isTrue);
      final unknownOperations = (await unknownOutbox.list('7')).successData;
      expect(unknownOperations.first.requiresStatusProbe, isTrue);
      expect(
        unknownOperations
            .skip(1)
            .every((operation) => !operation.requiresStatusProbe),
        isTrue,
      );

      final rejectedOutbox = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      final rejected = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: _FakeDocumentsRepository(
          createResult: Future.value(
            const FailureResult(ValidationFailure(message: 'bad lines')),
          ),
        ),
        outbox: rejectedOutbox,
        submissionStagingStore: _OutboxSubmissionStagingStore(),
        draftIdFactory: () => 'draft-rejected',
      )..addScannedProduct(_standardItem);

      await rejected.createDocument();
      expect(rejected.offlineSubmissionReview, isNull);
      expect((await rejectedOutbox.list('7')).successData, isEmpty);
      expect(rejected.formError, 'bad lines');
    },
  );

  test(
    'real datasource offers only unknown transport and rejects protocol unknown',
    () async {
      Future<({DocumentsViewModel viewModel, MemoryOutboxRepository outbox})>
      createViewModel(HttpClientAdapter adapter) async {
        final outbox = MemoryOutboxRepository(
          stateMachine: OutboxStateMachine(),
        );
        final repository = DocumentsRepositoryImpl(
          remoteDataSource: ApiDocumentsRemoteDataSource(
            ApiClient(
              dio: Dio()..httpClientAdapter = adapter,
              enableLogging: false,
            ),
          ),
        );
        final viewModel = _draftEnabledViewModel(
          drafts: _FakeDocumentDraftRepository(),
          documents: repository,
          outbox: outbox,
          submissionStagingStore: _OutboxSubmissionStagingStore(),
          draftIdFactory: () => 'real-datasource-draft',
        )..addScannedProduct(_standardItem);
        return (viewModel: viewModel, outbox: outbox);
      }

      final protocolUnknown = await createViewModel(
        _DocumentSubmitAdapter(body: '[]'),
      );
      await protocolUnknown.viewModel.createDocument();

      expect(protocolUnknown.viewModel.formError, 'Invalid API response');
      expect(protocolUnknown.viewModel.offlineSubmissionReview, isNull);

      final transportUnknown = await createViewModel(
        const _DocumentSubmitAdapter(throwUnknownTransport: true),
      );
      await transportUnknown.viewModel.createDocument();

      expect(transportUnknown.viewModel.offlineSubmissionReview, isNotNull);
      expect(
        await transportUnknown.viewModel.confirmOfflineSubmission(),
        isTrue,
      );

      for (final type in const [
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        final timedOut = await createViewModel(
          _DocumentSubmitAdapter(throwType: type),
        );
        await timedOut.viewModel.createDocument();
        expect(timedOut.viewModel.offlineSubmissionReview, isNotNull);
        expect(await timedOut.viewModel.confirmOfflineSubmission(), isTrue);
        expect(
          (await timedOut.outbox.list(
            '7',
          )).successData.first.requiresStatusProbe,
          isTrue,
        );
      }
    },
  );

  test('operator cannot select admin-only document actions', () {
    final viewModel = DocumentsViewModel(canManageAdminDocumentActions: false);

    expect(viewModel.actions.map((action) => action.label), [
      '销售出库',
      '采购入库',
      '退货入库',
      '盘点单',
    ]);

    viewModel.selectActionByLabel('调拨单');
    expect(viewModel.selectedAction.label, '销售出库');

    viewModel.selectActionByLabel('转标准');
    expect(viewModel.selectedAction.label, '销售出库');
  });

  test('filters recent documents by type status and keyword', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _draftSalesDocument,
        _completedInboundDocument,
        _completedStocktakeDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.visibleDocuments, [
      _draftSalesDocument,
      _completedInboundDocument,
      _completedStocktakeDocument,
    ]);

    viewModel.selectDocumentTypeFilter(2);
    expect(viewModel.visibleDocuments, [_draftSalesDocument]);

    viewModel.selectDocumentTypeFilter(null);
    viewModel.selectDocumentStatusFilter('已完成');
    expect(viewModel.visibleDocuments, [
      _completedInboundDocument,
      _completedStocktakeDocument,
    ]);

    viewModel.updateDocumentKeyword('PD2026');
    expect(viewModel.visibleDocuments, [_completedStocktakeDocument]);
  });

  test('load requests selected document type from repository', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([_draftSalesDocument]),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    viewModel.selectDocumentTypeFilter(2);
    await viewModel.load();

    expect(repository.lastListDocType, 2);
    expect(viewModel.recentDocuments, [_draftSalesDocument]);
  });

  test('filters recent documents by inclusive created date range', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _julyInboundDocument,
        _juneSalesDocument,
        _undatedDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    viewModel.selectDocumentDateRange(
      startDate: DateTime(2026, 7, 1),
      endDate: DateTime(2026, 7, 31),
    );

    expect(viewModel.visibleDocuments, [_julyInboundDocument]);

    viewModel.selectDocumentDateRange();
    expect(viewModel.visibleDocuments, [
      _julyInboundDocument,
      _juneSalesDocument,
      _undatedDocument,
    ]);
  });

  test('rejects missing selected product before creating document', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository)
      ..updateQuantity('');

    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '请选择商品并输入数量');
    expect(repository.createdRequest, isNull);
  });

  test('load exposes repository failure', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const FailureResult<List<DocumentRecord>>(
        NetworkFailure(message: '单据列表加载失败'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.errorMessage, '单据列表加载失败');
    expect(viewModel.recentDocuments, isEmpty);
  });

  test('reload failure keeps previously loaded recent documents', () async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_remoteDocument]),
        FailureResult<List<DocumentRecord>>(
          NetworkFailure(message: '单据列表刷新失败'),
        ),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '单据列表刷新失败');
    expect(viewModel.recentDocuments, [_remoteDocument]);
    expect(viewModel.visibleDocuments, [_remoteDocument]);
  });

  test('load exposes transaction failure without clearing documents', () async {
    final repository = _FakeDocumentsRepository(
      transactionResult: const FailureResult<List<TransactionRecord>>(
        NetworkFailure(message: '流水加载失败'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.recentDocuments, [_remoteDocument]);
    expect(viewModel.transactions, isEmpty);
    expect(viewModel.transactionError, '流水加载失败');
  });

  test('reload failure keeps previously loaded transactions', () async {
    final repository = _FakeDocumentsRepository(
      transactionResults: const [
        Success<List<TransactionRecord>>([_transactionRecord]),
        FailureResult<List<TransactionRecord>>(
          NetworkFailure(message: '流水刷新失败'),
        ),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();
    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.transactionError, '流水刷新失败');
    expect(viewModel.recentDocuments, [_remoteDocument]);
    expect(viewModel.transactions, [_transactionRecord]);
  });

  test(
    'createDocument submits request and prepends backend document',
    () async {
      final repository = _FakeDocumentsRepository();
      final inventoryRepository = _FakeInventoryRepository();
      final viewModel =
          DocumentsViewModel(
              repository: repository,
              inventoryRepository: inventoryRepository,
            )
            ..selectActionByLabel('销售出库')
            ..updateRemark('M9-E2E:run-42:sales')
            ..updateQuantity('3');

      await viewModel.searchProducts('矿泉水');
      viewModel.selectProduct(_standardItem);
      final created = await viewModel.createDocument();

      expect(created, isTrue);
      expect(viewModel.formError, isNull);
      expect(repository.createdRequest?.docType, 2);
      expect(repository.createdRequest?.productId, 10);
      expect(repository.createdRequest?.productName, '矿泉水 550ml');
      expect(repository.createdRequest?.quantity, 3);
      expect(repository.createdRequest?.retailPrice, 6.5);
      expect(repository.createdRequest?.remark, 'M9-E2E:run-42:sales');
      expect(inventoryRepository.lastKeyword, '矿泉水');
      expect(viewModel.recentDocuments.first.number, 'SO-20260626-001');
      expect(viewModel.recentDocuments.first.status, '待提交');
      expect(viewModel.remark, isEmpty);
    },
  );

  test('document action switch preserves remark draft', () {
    final viewModel = DocumentsViewModel()
      ..updateRemark('M9-E2E:run-42:inbound');

    viewModel.selectActionByLabel('采购入库');

    expect(viewModel.remark, 'M9-E2E:run-42:inbound');
  });

  test(
    'createDocument fills submitted line when backend returns header only',
    () async {
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(
          const Success<DocumentRecord>(_createdHeaderOnlyDocument),
        ),
      );
      final viewModel = DocumentsViewModel(repository: repository)
        ..selectActionByLabel('销售出库')
        ..selectProduct(_standardItem)
        ..updateQuantity('3');

      final created = await viewModel.createDocument();

      expect(created, isTrue);
      expect(viewModel.recentDocuments.first.id, 700);
      expect(viewModel.recentDocuments.first.number, 'XS20260706005');
      expect(viewModel.recentDocuments.first.productName, '矿泉水 550ml');
      expect(viewModel.recentDocuments.first.quantity, 3);
    },
  );

  test('createDocument ignores duplicate submit while pending', () async {
    final pending = Completer<Result<DocumentRecord>>();
    final repository = _FakeDocumentsRepository(createResult: pending.future);
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectProduct(_standardItem)
      ..updateQuantity('3');

    final firstSubmit = viewModel.createDocument();
    expect(viewModel.isSubmitting, isTrue);

    final duplicateSubmit = viewModel.createDocument();
    await Future<void>.delayed(Duration.zero);

    expect(repository.createCallCount, 1);

    pending.complete(const Success<DocumentRecord>(_remoteDocument));

    expect(await duplicateSubmit, isFalse);
    expect(await firstSubmit, isTrue);
    expect(viewModel.recentDocuments, [_remoteDocument]);
  });

  test('submission barrier rejects every document form mutation', () async {
    final pending = Completer<Result<DocumentRecord>>();
    final repository = _FakeDocumentsRepository(createResult: pending.future);
    final viewModel =
        DocumentsViewModel(
            repository: repository,
            warehouses: const [_shanghaiWarehouse, _beijingWarehouse],
            currentWarehouse: _shanghaiWarehouse,
          )
          ..addProductToDraft(_standardItem, quantity: 2)
          ..updateRemark('before submit')
          ..updateAttachmentStagingIds(['before-file']);
    final initialEpoch = viewModel.submissionEpoch;

    final submit = viewModel.createDocument();
    expect(viewModel.isSubmitting, isTrue);
    expect(viewModel.submissionEpoch, initialEpoch + 1);

    viewModel.selectActionByLabel('采购入库');
    viewModel.updateProductName('blocked query');
    await viewModel.searchProducts('blocked search');
    viewModel.selectProduct(_staleItem);
    viewModel.addScannedProduct(_staleItem);
    viewModel.addProductToDraft(_staleItem, quantity: 3);
    viewModel.updateDraftLineQuantity(_standardItem.productId, 9);
    viewModel.removeDraftLine(_standardItem.productId);
    viewModel.selectNonStandardInventory(_nonStandardItem);
    viewModel.selectTargetWarehouse(_beijingWarehouse);
    viewModel.selectReturnSourceDocument(_completedSalesDocument);
    viewModel.updateQuantity('99');
    viewModel.updateRemark('blocked remark');
    viewModel.updateAttachmentStagingIds(['blocked-file']);

    expect(viewModel.selectedAction.docType, 2);
    expect(viewModel.productQuery, isEmpty);
    expect(viewModel.selectedProduct, isNull);
    expect(viewModel.draftLines.single.productId, _standardItem.productId);
    expect(viewModel.draftLines.single.quantity, 2);
    expect(viewModel.nonStandardSourceId, isNull);
    expect(viewModel.selectedTargetWarehouse, isNull);
    expect(viewModel.selectedReturnSourceDocument, isNull);
    expect(viewModel.quantityText, isEmpty);
    expect(viewModel.remark, 'before submit');
    expect(viewModel.attachmentStagingIds, ['before-file']);

    pending.complete(const Success(_remoteDocument));
    expect(await submit, isTrue);
  });

  test(
    'attachment removal blocks submit and failed submit keeps reconciled ids',
    () async {
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(
          const FailureResult<DocumentRecord>(NetworkFailure(message: '提交失败')),
        ),
      );
      final viewModel =
          DocumentsViewModel(
              repository: repository,
              draftIdFactory: () => 'attachment-draft',
            )
            ..addProductToDraft(_standardItem, quantity: 2)
            ..updateAttachmentStagingIds(['remove-me']);
      final draftId = viewModel.ensureDraftId();

      viewModel.setAttachmentMutationInProgress(true);
      expect(await viewModel.createDocument(), isFalse);
      expect(repository.createCallCount, 0);
      expect(viewModel.attachmentStagingIds, ['remove-me']);

      viewModel.reconcileAttachmentStagingIds(draftId, const []);
      viewModel.setAttachmentMutationInProgress(false);
      expect(await viewModel.createDocument(), isFalse);

      expect(repository.createCallCount, 1);
      expect(viewModel.attachmentStagingIds, isEmpty);
      expect(viewModel.formError, '提交失败');
    },
  );

  test('createDocument surfaces repository failure', () async {
    final repository = _FakeDocumentsRepository(
      createResult: Future.value(
        const FailureResult<DocumentRecord>(NetworkFailure(message: '单据服务不可用')),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..updateQuantity('3');

    viewModel.selectProduct(_standardItem);
    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '单据服务不可用');
    expect(viewModel.recentDocuments, isEmpty);
  });

  test('searchProducts exposes inventory candidates', () async {
    final inventoryRepository = _FakeInventoryRepository();
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
      inventoryRepository: inventoryRepository,
    );

    await viewModel.searchProducts('SKU-WA');

    expect(viewModel.productQuery, 'SKU-WA');
    expect(viewModel.productCandidates, [_standardItem]);
    expect(viewModel.isSearchingProducts, isFalse);
  });

  test('searchProducts ignores stale product results', () async {
    final firstSearch = Completer<Result<PageData<InventoryItem>>>();
    final secondSearch = Completer<Result<PageData<InventoryItem>>>();
    final inventoryRepository = _FakeInventoryRepository(
      inventorySearchResults: [firstSearch.future, secondSearch.future],
    );
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
      inventoryRepository: inventoryRepository,
    );

    final olderSearch = viewModel.searchProducts('旧商品');
    final newerSearch = viewModel.searchProducts('矿泉水');

    secondSearch.complete(Success(_inventoryPage([_standardItem])));
    await newerSearch;

    expect(viewModel.productQuery, '矿泉水');
    expect(viewModel.productCandidates, [_standardItem]);

    firstSearch.complete(Success(_inventoryPage([_staleItem])));
    await olderSearch;

    expect(inventoryRepository.inventoryKeywords, ['旧商品', '矿泉水']);
    expect(viewModel.productQuery, '矿泉水');
    expect(viewModel.productCandidates, [_standardItem]);
    expect(viewModel.isSearchingProducts, isFalse);
  });

  test(
    'search result issued before submit cannot mutate the form later',
    () async {
      final searchResult = Completer<Result<PageData<InventoryItem>>>();
      final createResult = Completer<Result<DocumentRecord>>();
      final viewModel = DocumentsViewModel(
        repository: _FakeDocumentsRepository(createResult: createResult.future),
        inventoryRepository: _FakeInventoryRepository(
          inventorySearchResults: [searchResult.future],
        ),
      )..addProductToDraft(_standardItem, quantity: 2);

      final search = viewModel.searchProducts('late search');
      await Future<void>.delayed(Duration.zero);
      final submit = viewModel.createDocument();
      expect(viewModel.isSubmitting, isTrue);
      searchResult.complete(Success(_inventoryPage([_staleItem])));
      await search;

      expect(viewModel.productCandidates, isEmpty);
      expect(viewModel.isSearchingProducts, isFalse);

      createResult.complete(const Success(_remoteDocument));
      expect(await submit, isTrue);
    },
  );

  test('transfer document requires a target warehouse', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel =
        DocumentsViewModel(
            repository: repository,
            currentWarehouse: _shanghaiWarehouse,
            warehouses: const [_shanghaiWarehouse, _beijingWarehouse],
          )
          ..selectActionByLabel('调拨单')
          ..selectProduct(_standardItem)
          ..updateQuantity('3');

    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '请选择调拨目标仓库');
    expect(repository.createdRequest, isNull);
    expect(viewModel.targetWarehouses, [_beijingWarehouse]);
  });

  test('transfer document submits target warehouse id', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel =
        DocumentsViewModel(
            repository: repository,
            currentWarehouse: _shanghaiWarehouse,
            warehouses: const [_shanghaiWarehouse, _beijingWarehouse],
          )
          ..selectActionByLabel('调拨单')
          ..selectProduct(_standardItem)
          ..selectTargetWarehouse(_beijingWarehouse)
          ..updateQuantity('3');

    final created = await viewModel.createDocument();

    expect(created, isTrue);
    expect(repository.createdRequest?.docType, 4);
    expect(repository.createdRequest?.toWarehouseId, 2);
    expect(repository.createdRequest?.retailPrice, isNull);
  });

  test('return document requires a completed source sales document', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _completedSalesDocument,
        _draftSalesDocument,
        _completedInboundDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('退货入库')
      ..selectProduct(_standardItem)
      ..updateQuantity('1');

    await viewModel.load();
    final created = await viewModel.createDocument();

    expect(viewModel.returnSourceDocuments, [_completedSalesDocument]);
    expect(created, isFalse);
    expect(viewModel.formError, '请选择原销售单');
    expect(repository.createdRequest, isNull);
  });

  test('return document submits source sales document id', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _completedSalesDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('退货入库')
      ..selectProduct(_standardItem)
      ..selectReturnSourceDocument(_completedSalesDocument)
      ..updateQuantity('1');

    final created = await viewModel.createDocument();

    expect(created, isTrue);
    expect(repository.createdRequest?.docType, 3);
    expect(repository.createdRequest?.refDocId, 136);
  });

  test('return document clears stale source after documents reload', () async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_completedSalesDocument]),
        Success<List<DocumentRecord>>([_completedInboundDocument]),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('退货入库')
      ..selectProduct(_standardItem)
      ..updateQuantity('1');

    await viewModel.load();
    viewModel.selectReturnSourceDocument(_completedSalesDocument);

    await viewModel.load();

    expect(viewModel.returnSourceDocuments, isEmpty);
    expect(viewModel.selectedReturnSourceDocument, isNull);

    final created = await viewModel.createDocument();

    expect(created, isFalse);
    expect(viewModel.formError, '请选择原销售单');
    expect(repository.createdRequest, isNull);
  });

  test('return source loader queries completed sales documents only', () async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _completedSalesDocument,
        _draftSalesDocument,
        _completedInboundDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('退货入库');

    await viewModel.loadReturnSourceDocuments();

    expect(repository.listDocTypes, [2]);
    expect(viewModel.returnSourceDocuments, [_completedSalesDocument]);
    expect(viewModel.returnSourceError, isNull);
  });

  test(
    'return source loader clears stale source after reload failure',
    () async {
      final repository = _FakeDocumentsRepository(
        listResults: const [
          Success<List<DocumentRecord>>([_completedSalesDocument]),
          FailureResult<List<DocumentRecord>>(
            NetworkFailure(message: '销售单加载失败'),
          ),
        ],
      );
      final viewModel = DocumentsViewModel(repository: repository)
        ..selectActionByLabel('退货入库');

      await viewModel.loadReturnSourceDocuments();
      viewModel.selectReturnSourceDocument(_completedSalesDocument);
      await viewModel.loadReturnSourceDocuments();

      expect(repository.listDocTypes, [2, 2]);
      expect(viewModel.returnSourceDocuments, isEmpty);
      expect(viewModel.selectedReturnSourceDocument, isNull);
      expect(viewModel.returnSourceError, '销售单加载失败');
    },
  );

  testWidgets(
    'page startup restores pending return source after delayed load',
    (tester) async {
      final sourceResult = Completer<Result<List<DocumentRecord>>>();
      final draft = _returnDraft('delayed-return', sourceDocumentId: 136);
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(loaded: draft),
        documents: _FakeDocumentsRepository(listFuture: sourceResult.future),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentsPage(viewModel: viewModel, initialDraftId: draft.id),
          ),
        ),
      );
      await tester.pump();

      expect(viewModel.pendingReturnSourceDocumentId, 136);
      expect(viewModel.selectedReturnSourceDocument, isNull);
      sourceResult.complete(
        const Success<List<DocumentRecord>>([_completedSalesDocument]),
      );
      await tester.pumpAndSettle();

      expect(viewModel.pendingReturnSourceDocumentId, isNull);
      expect(viewModel.selectedReturnSourceDocument?.id, 136);
      expect(viewModel.returnSourceError, isNull);
    },
  );

  test('expired pending return source is cleared with visible error', () async {
    final draft = _returnDraft('expired-return', sourceDocumentId: 999);
    final viewModel = _draftEnabledViewModel(
      drafts: _FakeDocumentDraftRepository(loaded: draft),
      documents: _FakeDocumentsRepository(
        listResult: const Success<List<DocumentRecord>>([]),
      ),
    );
    await viewModel.openDraft(draft.id);

    await viewModel.loadReturnSourceDocuments();

    expect(viewModel.pendingReturnSourceDocumentId, isNull);
    expect(viewModel.selectedReturnSourceDocument, isNull);
    expect(viewModel.returnSourceError, '原销售单已失效，请重新选择');
  });

  test('stocktake document submits actual quantity and allows zero', () async {
    final repository = _FakeDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('盘点单')
      ..selectProduct(_standardItem)
      ..updateQuantity('0');

    final created = await viewModel.createDocument();

    expect(created, isTrue);
    expect(repository.createdRequest?.docType, 5);
    expect(repository.createdRequest?.actualQuantity, 0);
    expect(repository.createdRequest?.quantity, 0);
  });

  test(
    'conversion document requires a non-standard inventory source',
    () async {
      final repository = _FakeDocumentsRepository();
      final inventoryRepository = _FakeInventoryRepository();
      final viewModel =
          DocumentsViewModel(
              repository: repository,
              inventoryRepository: inventoryRepository,
            )
            ..selectActionByLabel('转标准')
            ..selectProduct(_standardItem)
            ..updateQuantity('2');

      await viewModel.loadNonStandardInventory();
      final created = await viewModel.createDocument();

      expect(viewModel.nonStandardInventoryItems, [_nonStandardItem]);
      expect(created, isFalse);
      expect(viewModel.formError, '请选择非标库存');
      expect(repository.createdRequest, isNull);
    },
  );

  test('non-standard conversion selection traverses every page', () async {
    final inventoryRepository = _FakeInventoryRepository(
      nonStandardInventoryResults: [
        Success(
          _nonStandardPage([_nonStandardItem], total: 2, page: 1, pageSize: 1),
        ),
        Success(
          _nonStandardPage(
            [_secondNonStandardItem],
            total: 2,
            page: 2,
            pageSize: 1,
          ),
        ),
      ],
    );
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
      inventoryRepository: inventoryRepository,
    )..selectActionByLabel('转标准');

    await viewModel.loadNonStandardInventory();

    expect(inventoryRepository.nonStandardInventoryPages, [1, 2]);
    expect(viewModel.nonStandardInventoryItems, [
      _nonStandardItem,
      _secondNonStandardItem,
    ]);
  });

  test(
    'conversion document submits source non-standard inventory id',
    () async {
      final repository = _FakeDocumentsRepository();
      final inventoryRepository = _FakeInventoryRepository();
      final viewModel =
          DocumentsViewModel(
              repository: repository,
              inventoryRepository: inventoryRepository,
            )
            ..selectActionByLabel('转标准')
            ..selectProduct(_standardItem)
            ..selectNonStandardInventory(_nonStandardItem)
            ..updateQuantity('2');

      final created = await viewModel.createDocument();

      expect(created, isTrue);
      expect(repository.createdRequest?.docType, 6);
      expect(repository.createdRequest?.nonStdInventoryId, 11);
      expect(repository.createdRequest?.productId, 10);
      expect(repository.createdRequest?.quantity, 2);
    },
  );

  test(
    'conversion document clears stale source after inventory reload',
    () async {
      final repository = _FakeDocumentsRepository();
      final inventoryRepository = _FakeInventoryRepository(
        nonStandardInventoryResults: [
          Success(_nonStandardPage([_nonStandardItem])),
          Success(_nonStandardPage([])),
        ],
      );
      final viewModel =
          DocumentsViewModel(
              repository: repository,
              inventoryRepository: inventoryRepository,
            )
            ..selectActionByLabel('转标准')
            ..selectProduct(_standardItem)
            ..updateQuantity('2');

      await viewModel.loadNonStandardInventory();
      viewModel.selectNonStandardInventory(_nonStandardItem);

      await viewModel.loadNonStandardInventory();

      expect(viewModel.nonStandardInventoryItems, isEmpty);
      expect(viewModel.selectedNonStandardInventory, isNull);

      final created = await viewModel.createDocument();

      expect(created, isFalse);
      expect(viewModel.formError, '请选择非标库存');
      expect(repository.createdRequest, isNull);
    },
  );

  test(
    'completeDocument posts lifecycle action and reloads documents',
    () async {
      final repository = _FakeDocumentsRepository(
        listResults: const [
          Success<List<DocumentRecord>>([_draftSalesDocument]),
          Success<List<DocumentRecord>>([_completedDraftSalesDocument]),
        ],
      );
      final viewModel = DocumentsViewModel(repository: repository);

      await viewModel.load();
      final completed = await viewModel.completeDocument(_draftSalesDocument);

      expect(completed, isTrue);
      expect(repository.completedDocumentId, 137);
      expect(repository.listCallCount, 2);
      expect(viewModel.recentDocuments, [_completedDraftSalesDocument]);
      expect(viewModel.documentActionError, isNull);
    },
  );

  test(
    'completeDocument ignores duplicate lifecycle action while pending',
    () async {
      final pending = Completer<Result<void>>();
      final repository = _FakeDocumentsRepository(
        completeResult: pending.future,
        listResults: const [
          Success<List<DocumentRecord>>([_completedDraftSalesDocument]),
        ],
      );
      final viewModel = DocumentsViewModel(repository: repository);

      final firstComplete = viewModel.completeDocument(_draftSalesDocument);
      expect(viewModel.isCompletingDocument(_draftSalesDocument), isTrue);

      final duplicateComplete = viewModel.completeDocument(_draftSalesDocument);
      await Future<void>.delayed(Duration.zero);

      expect(repository.completeCallCount, 1);

      pending.complete(const Success<void>(null));

      expect(await duplicateComplete, isFalse);
      expect(await firstComplete, isTrue);
      expect(viewModel.recentDocuments, [_completedDraftSalesDocument]);
    },
  );

  test('completeDocument exposes backend lifecycle failure', () async {
    final repository = _FakeDocumentsRepository(
      completeResult: Future.value(
        const FailureResult<void>(InventoryFailure(message: '库存不足')),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    final completed = await viewModel.completeDocument(_draftSalesDocument);

    expect(completed, isFalse);
    expect(repository.completedDocumentId, 137);
    expect(viewModel.documentActionError, '库存不足');
  });

  test(
    'existing authoritative document queues direct lifecycle without create',
    () async {
      final repository = _FakeDocumentsRepository(
        completeResult: Future.value(
          const FailureResult<void>(NetworkFailure()),
        ),
      );
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: repository,
        outbox: outbox,
      );

      expect(await viewModel.completeDocument(_draftSalesDocument), isFalse);
      expect((await outbox.list('7')).successData, isEmpty);
      expect(viewModel.offlineSubmissionReview?.documentType, isNotEmpty);
      expect(await viewModel.confirmOfflineSubmission(), isTrue);

      final queued = (await outbox.list('7')).successData;
      expect(queued.map((operation) => operation.kind), [
        OutboxOperationKind.documentReference,
        OutboxOperationKind.documentComplete,
      ]);
      expect(
        queued.map((operation) => operation.kind),
        isNot(contains(OutboxOperationKind.documentCreate)),
      );
      expect(queued.first.payload, {
        'version': 1,
        'documentId': _draftSalesDocument.id,
        'expectedDocType': _draftSalesDocument.docType,
        'expectedStatus': _draftSalesDocument.status,
        'lifecycleIntent': 'document_complete',
      });
      expect(queued.last.payload, {'version': 1});
      expect(queued.last.idempotencyKey, repository.completedRequestIds.single);

      for (final operation in queued) {
        await outbox.confirm(
          accountId: '7',
          operationId: operation.operationId,
        );
      }
      expect((await outbox.ready('7')).successData.map((item) => item.kind), [
        OutboxOperationKind.documentReference,
      ]);
      await outbox.transition(
        accountId: '7',
        operationId: queued.first.operationId,
        next: OutboxState.syncing,
      );
      await outbox.completeSuccess(
        accountId: '7',
        operationId: queued.first.operationId,
        output: OutboxOperationOutput(
          version: 1,
          data: {'documentId': _draftSalesDocument.id},
        ),
      );
      expect((await outbox.ready('7')).successData.map((item) => item.kind), [
        OutboxOperationKind.documentComplete,
      ]);
    },
  );

  test(
    'existing stocktake settle queues a verified reference snapshot',
    () async {
      final repository = _FakeDocumentsRepository(
        settleResult: const FailureResult<void>(TransportUnknownFailure()),
      );
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _draftEnabledViewModel(
        drafts: _FakeDocumentDraftRepository(),
        documents: repository,
        outbox: outbox,
      );

      expect(
        await viewModel.settleStocktakeDocument(_confirmedStocktakeDocument),
        isFalse,
      );
      expect(await viewModel.confirmOfflineSubmission(), isTrue);

      final queued = (await outbox.list('7')).successData;
      expect(queued.map((operation) => operation.kind), [
        OutboxOperationKind.documentReference,
        OutboxOperationKind.stocktakeSettle,
      ]);
      expect(queued.first.payload, {
        'version': 1,
        'documentId': _confirmedStocktakeDocument.id,
        'expectedDocType': 5,
        'expectedStatus': '差异已确认',
        'lifecycleIntent': 'stocktake_settle',
      });
      expect(queued.last.requiresStatusProbe, isTrue);
      expect(queued.last.idempotencyKey, repository.settledRequestIds.single);
    },
  );

  test(
    'operator cannot complete admin-only documents even when visible',
    () async {
      final repository = _FakeDocumentsRepository();
      final viewModel = DocumentsViewModel(
        repository: repository,
        canManageAdminDocumentActions: false,
      );

      expect(viewModel.canCompleteDocument(_draftTransferDocument), isFalse);
      expect(viewModel.canCompleteDocument(_draftConversionDocument), isFalse);

      final completedTransfer = await viewModel.completeDocument(
        _draftTransferDocument,
      );
      final completedConversion = await viewModel.completeDocument(
        _draftConversionDocument,
      );

      expect(completedTransfer, isFalse);
      expect(completedConversion, isFalse);
      expect(viewModel.documentActionError, '无权限操作该单据');
      expect(repository.completeCallCount, 0);
    },
  );

  test('stocktake lifecycle exposes confirm and settle availability', () {
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
    );

    expect(
      viewModel.canConfirmStocktakeDocument(_countingStocktakeDocument),
      isTrue,
    );
    expect(
      viewModel.canSettleStocktakeDocument(_countingStocktakeDocument),
      isFalse,
    );
    expect(
      viewModel.canConfirmStocktakeDocument(_confirmedStocktakeDocument),
      isFalse,
    );
    expect(
      viewModel.canSettleStocktakeDocument(_confirmedStocktakeDocument),
      isTrue,
    );
  });

  test('confirmStocktakeDocument posts lifecycle action and reloads', () async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_countingStocktakeDocument]),
        Success<List<DocumentRecord>>([_confirmedStocktakeDocument]),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();
    final confirmed = await viewModel.confirmStocktakeDocument(
      _countingStocktakeDocument,
    );

    expect(confirmed, isTrue);
    expect(repository.confirmedDocumentId, 501);
    expect(repository.listCallCount, 2);
    expect(viewModel.recentDocuments, [_confirmedStocktakeDocument]);
    expect(viewModel.documentActionError, isNull);
  });

  test('confirmStocktakeDocument exposes backend state failure', () async {
    final repository = _FakeDocumentsRepository(
      confirmResult: const FailureResult<void>(
        StateFailure(message: '盘点单状态无效'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    final confirmed = await viewModel.confirmStocktakeDocument(
      _countingStocktakeDocument,
    );

    expect(confirmed, isFalse);
    expect(repository.confirmedDocumentId, 501);
    expect(viewModel.documentActionError, '盘点单状态无效');
  });

  test('settleStocktakeDocument posts lifecycle action and reloads', () async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_confirmedStocktakeDocument]),
        Success<List<DocumentRecord>>([_settledStocktakeDocument]),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();
    final settled = await viewModel.settleStocktakeDocument(
      _confirmedStocktakeDocument,
    );

    expect(settled, isTrue);
    expect(repository.settledDocumentId, 501);
    expect(repository.listCallCount, 2);
    expect(viewModel.recentDocuments, [_settledStocktakeDocument]);
    expect(viewModel.documentActionError, isNull);
  });

  test('settleStocktakeDocument exposes backend state failure', () async {
    final repository = _FakeDocumentsRepository(
      settleResult: const FailureResult<void>(
        StateFailure(message: '库存已变化，请重新盘点'),
      ),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    final settled = await viewModel.settleStocktakeDocument(
      _confirmedStocktakeDocument,
    );

    expect(settled, isFalse);
    expect(repository.settledDocumentId, 501);
    expect(viewModel.documentActionError, '库存已变化，请重新盘点');
  });

  testWidgets('document scan button adds returned product to the draft', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel();
    var scanCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(
            viewModel: viewModel,
            onScanRequested: (_) async {
              scanCalls += 1;
              return _standardItem;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('document-scan-product-button')));
    await tester.pumpAndSettle();

    expect(scanCalls, 1);
    expect(find.byKey(const Key('document-draft-line-10')), findsOneWidget);
    expect(find.text('数量 1'), findsOneWidget);
  });

  testWidgets(
    'DocumentsPage publishes global refresh after creating document',
    (tester) async {
      final repository = _FakeDocumentsRepository();
      final eventBus = AppEventBus();
      final viewModel = DocumentsViewModel(repository: repository)
        ..selectProduct(_standardItem)
        ..updateQuantity('3');
      var refreshCount = 0;
      final subscription = eventBus.on<GlobalRefreshRequestedEvent>().listen((
        _,
      ) {
        refreshCount += 1;
      });
      addTearDown(subscription.cancel);
      addTearDown(eventBus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentsPage(viewModel: viewModel, eventBus: eventBus),
          ),
        ),
      );

      await tester.ensureVisible(
        find.byKey(const Key('document-create-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-create-button')));
      await tester.pumpAndSettle();

      expect(repository.createdRequest, isNotNull);
      expect(refreshCount, 1);
    },
  );

  testWidgets('DocumentsPage exposes stable E2E action and list keys', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('documents-scroll-view')), findsOneWidget);
    expect(find.byKey(const Key('document-action-inbound')), findsOneWidget);
    expect(find.byKey(const Key('document-action-sales')), findsOneWidget);
    for (var attempt = 0; attempt < 8; attempt += 1) {
      if (find.byKey(const Key('document-list-item-1')).evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();
    }
    expect(find.byKey(const Key('document-list-item-1')), findsOneWidget);
  });

  testWidgets('DocumentsPage clears create form fields after success', (
    tester,
  ) async {
    final repository = _FakeDocumentsRepository();
    final inventoryRepository = _FakeInventoryRepository();
    final viewModel = DocumentsViewModel(
      repository: repository,
      inventoryRepository: inventoryRepository,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('document-product-field')),
      '矿泉水',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-product-option-10')));
    await tester.pumpAndSettle();
    final selectedProductEditable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('document-product-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(selectedProductEditable.controller.text, '矿泉水 550ml');

    await tester.enterText(
      find.byKey(const Key('document-quantity-field')),
      '3',
    );
    await tester.enterText(
      find.byKey(const Key('document-remark-field')),
      'M9-E2E:run-42:sales',
    );

    final remarkField = tester.widget<TextField>(
      find.byKey(const Key('document-remark-field')),
    );
    expect(remarkField.decoration?.labelText, '备注');
    expect(remarkField.maxLength, 512);

    await tester.ensureVisible(find.byKey(const Key('document-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-create-button')));
    await tester.pumpAndSettle();

    final productEditable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('document-product-field')),
        matching: find.byType(EditableText),
      ),
    );
    final quantityEditable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('document-quantity-field')),
        matching: find.byType(EditableText),
      ),
    );
    final remarkEditable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('document-remark-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(repository.createdRequest?.productName, '矿泉水 550ml');
    expect(repository.createdRequest?.remark, 'M9-E2E:run-42:sales');
    expect(productEditable.controller.text, isEmpty);
    expect(quantityEditable.controller.text, isEmpty);
    expect(remarkEditable.controller.text, isEmpty);
    expect(find.text('已选择 矿泉水 550ml · SKU-WA-550'), findsNothing);
  });

  testWidgets(
    'DocumentsPage locks and atomically clears form during delayed refresh',
    (tester) async {
      final repository = _DelayedCreationRefreshRepository();
      final viewModel = DocumentsViewModel(
        repository: repository,
        inventoryRepository: _FakeInventoryRepository(),
      );
      await viewModel.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('document-product-field')),
        '矿泉水',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-product-option-10')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('document-quantity-field')),
        '3',
      );
      await tester.enterText(
        find.byKey(const Key('document-remark-field')),
        'M9-E2E:run-42:sales',
      );
      await tester.ensureVisible(
        find.byKey(const Key('document-create-button')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('document-create-button')));
      await repository.waitForRefreshCall();
      await tester.pump();

      expect(viewModel.isSubmitting, isTrue);
      for (final key in const [
        Key('document-product-field'),
        Key('document-quantity-field'),
        Key('document-remark-field'),
      ]) {
        final field = tester.widget<TextField>(find.byKey(key));
        expect(field.enabled, isFalse);
        expect(field.onChanged, isNull);
        final editable = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable.controller.text, isEmpty);
      }
      expect(viewModel.productQuery, isEmpty);
      expect(viewModel.quantityText, isEmpty);
      expect(viewModel.remark, isEmpty);

      repository.completeRefresh();
      await tester.pumpAndSettle();

      expect(viewModel.isSubmitting, isFalse);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('document-remark-field')))
            .enabled,
        isTrue,
      );
      expect(viewModel.remark, isEmpty);
    },
  );

  testWidgets('DocumentsPage disables all form commands during submit', (
    tester,
  ) async {
    final pending = Completer<Result<DocumentRecord>>();
    final repository = _FakeDocumentsRepository(createResult: pending.future);
    final viewModel =
        DocumentsViewModel(
            repository: repository,
            warehouses: const [_shanghaiWarehouse, _beijingWarehouse],
            currentWarehouse: _shanghaiWarehouse,
            draftIdFactory: () => 'submit-ui-draft',
          )
          ..selectActionByLabel('调拨单')
          ..selectTargetWarehouse(_beijingWarehouse)
          ..addProductToDraft(_standardItem, quantity: 2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(
            viewModel: viewModel,
            attachmentPicker: _PageDraftPicker(),
            attachmentStagingStore: _PageDraftStaging(),
            attachmentUserId: '7',
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('document-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-create-button')));
    await tester.pump();
    expect(viewModel.isSubmitting, isTrue);

    final actionInkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('document-action-sales'), skipOffstage: false),
        matching: find.byType(InkWell, skipOffstage: false),
      ),
    );
    final targetSelector = tester.widget<DropdownButtonFormField<int>>(
      find.byKey(const Key('document-target-warehouse-selector')),
    );
    final removeLine = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(Key('document-draft-line-${_standardItem.productId}')),
        matching: find.byType(IconButton),
      ),
    );
    final attachmentButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const Key('document-draft-attachment-file')),
        matching: find.byType(IconButton),
      ),
    );
    expect(actionInkWell.onTap, isNull);
    expect(targetSelector.onChanged, isNull);
    expect(removeLine.onPressed, isNull);
    expect(attachmentButton.onPressed, isNull);

    pending.complete(const Success(_remoteDocument));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'delayed attachment remove stays consistent across a failed submit',
    (tester) async {
      final removeResult = Completer<Result<void>>();
      final staging = _PageDraftStaging(removeResult: removeResult.future);
      final repository = _FakeDocumentsRepository(
        createResult: Future.value(
          const FailureResult<DocumentRecord>(NetworkFailure(message: '提交失败')),
        ),
      );
      final viewModel = DocumentsViewModel(
        repository: repository,
        draftIdFactory: () => 'remove-ui-draft',
      )..addProductToDraft(_standardItem, quantity: 2);
      final draftId = viewModel.ensureDraftId();
      staging.items.add(_pageStaged('remove-ui', draftId));
      viewModel.updateAttachmentStagingIds(['remove-ui']);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentsPage(
              viewModel: viewModel,
              attachmentPicker: _PageDraftPicker(),
              attachmentStagingStore: staging,
              attachmentUserId: '7',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byTooltip('移除暂存附件'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('移除暂存附件'));
      await staging.removeStarted.future;
      await tester.pump();

      expect(viewModel.isAttachmentMutationInProgress, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('document-create-button')),
            )
            .onPressed,
        isNull,
      );
      expect(viewModel.attachmentStagingIds, ['remove-ui']);
      expect(staging.items, hasLength(1));
      expect(find.text('remove-ui.pdf'), findsOneWidget);
      expect(await viewModel.createDocument(), isFalse);
      expect(repository.createCallCount, 0);

      removeResult.complete(const Success(null));
      await tester.pumpAndSettle();

      expect(viewModel.isAttachmentMutationInProgress, isFalse);
      expect(viewModel.attachmentStagingIds, isEmpty);
      expect(staging.items, isEmpty);
      expect(find.text('remove-ui.pdf'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const Key('document-create-button')),
      );
      await tester.tap(find.byKey(const Key('document-create-button')));
      await tester.pumpAndSettle();

      expect(repository.createCallCount, 1);
      expect(viewModel.formError, '提交失败');
      expect(viewModel.attachmentStagingIds, isEmpty);
      expect(staging.items, isEmpty);
      expect(find.text('remove-ui.pdf'), findsNothing);
    },
  );

  testWidgets('DocumentsPage clears transfer target selector after success', (
    tester,
  ) async {
    final repository = _FakeDocumentsRepository();
    final inventoryRepository = _FakeInventoryRepository();
    final viewModel = DocumentsViewModel(
      repository: repository,
      inventoryRepository: inventoryRepository,
      currentWarehouse: _shanghaiWarehouse,
      warehouses: const [_shanghaiWarehouse, _beijingWarehouse],
    )..selectActionByLabel('调拨单');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('document-product-field')),
      '矿泉水',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-product-option-10')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('document-target-warehouse-selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('北京仓').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('document-quantity-field')),
      '3',
    );

    expect(find.text('北京仓'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('document-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-create-button')));
    await tester.pumpAndSettle();

    expect(repository.createdRequest?.docType, 4);
    expect(repository.createdRequest?.toWarehouseId, 2);
    expect(viewModel.selectedTargetWarehouse, isNull);
    expect(find.text('北京仓'), findsNothing);
  });

  testWidgets('DocumentsPage loads return source documents after action tap', (
    tester,
  ) async {
    final repository = _FakeDocumentsRepository(
      listResult: const Success<List<DocumentRecord>>([
        _completedSalesDocument,
      ]),
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.tap(find.text('退货入库'));
    await tester.pumpAndSettle();

    expect(repository.listDocTypes, [2]);
    expect(
      find.byKey(const Key('document-return-source-selector')),
      findsOneWidget,
    );
  });

  testWidgets(
    'DocumentsPage publishes global refresh after completing document',
    (tester) async {
      final repository = _FakeDocumentsRepository(
        listResults: const [
          Success<List<DocumentRecord>>([_draftSalesDocument]),
          Success<List<DocumentRecord>>([_completedDraftSalesDocument]),
          Success<List<DocumentRecord>>([_completedDraftSalesDocument]),
        ],
      );
      final eventBus = AppEventBus();
      final viewModel = DocumentsViewModel(repository: repository);
      var refreshCount = 0;
      final subscription = eventBus.on<GlobalRefreshRequestedEvent>().listen((
        _,
      ) {
        refreshCount += 1;
      });
      addTearDown(subscription.cancel);
      addTearDown(eventBus.dispose);

      await viewModel.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentsPage(viewModel: viewModel, eventBus: eventBus),
          ),
        ),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('document-complete-137')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('document-complete-137')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认完成'));
      await tester.pumpAndSettle();

      expect(repository.completedDocumentId, 137);
      expect(refreshCount, 1);
    },
  );

  testWidgets('DocumentsPage opens document detail and runs available action', (
    tester,
  ) async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_remoteDocument]),
        Success<List<DocumentRecord>>([_completedRemoteDocument]),
        Success<List<DocumentRecord>>([_completedRemoteDocument]),
      ],
    );
    final eventBus = AppEventBus();
    final viewModel = DocumentsViewModel(repository: repository);
    var refreshCount = 0;
    final subscription = eventBus.on<GlobalRefreshRequestedEvent>().listen((_) {
      refreshCount += 1;
    });
    addTearDown(subscription.cancel);
    addTearDown(eventBus.dispose);

    await viewModel.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(viewModel: viewModel, eventBus: eventBus),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('SO-20260626-001 · 矿泉水 550ml x3'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('SO-20260626-001 · 矿泉水 550ml x3'));
    await tester.pumpAndSettle();

    expect(find.text('单据详情'), findsOneWidget);
    expect(find.text('单号'), findsOneWidget);
    expect(find.text('SO-20260626-001'), findsWidgets);
    expect(find.text('销售出库'), findsWidgets);
    expect(find.text('商品明细'), findsOneWidget);
    expect(find.text('矿泉水 550ml'), findsOneWidget);
    expect(find.text('x3'), findsWidgets);
    expect(find.text('完成单据'), findsOneWidget);

    await tester.tap(find.text('完成单据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认完成'));
    await tester.pumpAndSettle();

    expect(repository.completedDocumentId, 1);
    expect(refreshCount, 1);
  });

  testWidgets(
    'DocumentsPage detail replaces list summary with authoritative lines',
    (tester) async {
      final repository = _FakeDocumentsRepository();
      final viewModel = DocumentsViewModel(repository: repository);
      await viewModel.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentsPage(viewModel: viewModel, repository: repository),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('SO-20260626-001 · 矿泉水 550ml x3'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('SO-20260626-001 · 矿泉水 550ml x3'));
      await tester.pumpAndSettle();

      expect(repository.detailDocumentId, 1);
      expect(find.text('SKU-AUTH-1'), findsOneWidget);
      expect(find.text('权威明细商品'), findsOneWidget);
      expect(find.text('4 箱'), findsOneWidget);
    },
  );

  testWidgets('DocumentsPage keeps detail open and shows lifecycle failure', (
    tester,
  ) async {
    final repository = _FakeDocumentsRepository(
      completeResult: Future.value(
        const FailureResult<void>(InventoryFailure(message: '库存不足')),
      ),
    );
    final eventBus = AppEventBus();
    final viewModel = DocumentsViewModel(repository: repository);
    var refreshCount = 0;
    final subscription = eventBus.on<GlobalRefreshRequestedEvent>().listen((_) {
      refreshCount += 1;
    });
    addTearDown(subscription.cancel);
    addTearDown(eventBus.dispose);

    await viewModel.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(viewModel: viewModel, eventBus: eventBus),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('SO-20260626-001 · 矿泉水 550ml x3'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('SO-20260626-001 · 矿泉水 550ml x3'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('完成单据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认完成'));
    await tester.pumpAndSettle();

    expect(repository.completedDocumentId, 1);
    expect(refreshCount, 0);
    expect(find.text('单据详情'), findsOneWidget);
    expect(
      find.byKey(const Key('document-detail-action-error')),
      findsOneWidget,
    );
    expect(find.text('库存不足'), findsWidgets);
  });

  testWidgets('DocumentsPage filters recent documents from controls', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(
        listResult: const Success<List<DocumentRecord>>([
          _draftSalesDocument,
          _completedInboundDocument,
          _completedStocktakeDocument,
        ]),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('XS20260417036'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('XS20260417036'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('document-keyword-filter-field')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('document-keyword-filter-field')),
      'PD2026',
    );
    await tester.pump();

    expect(find.text('XS20260417036'), findsNothing);
    expect(find.text('RK20260417001'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('PD20260627002 · 低库存商品 x2'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PD20260627002 · 低库存商品 x2'), findsOneWidget);
  });

  testWidgets('DocumentsPage filters recent documents by date fields', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(
        listResult: const Success<List<DocumentRecord>>([
          _julyInboundDocument,
          _juneSalesDocument,
        ]),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('document-start-date-filter-field')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('document-start-date-filter-field')),
      '2026-07-01',
    );
    await tester.enterText(
      find.byKey(const Key('document-end-date-filter-field')),
      '2026-07-31',
    );
    await tester.pump();

    expect(find.text('RK20260702001 · 矿泉水 550ml x5'), findsOneWidget);
    expect(find.text('XS20260630001 · 矿泉水 550ml x3'), findsNothing);
  });

  testWidgets('DocumentsPage keeps date filter when date input is invalid', (
    tester,
  ) async {
    final viewModel = DocumentsViewModel(
      repository: _FakeDocumentsRepository(
        listResult: const Success<List<DocumentRecord>>([
          _julyInboundDocument,
          _juneSalesDocument,
        ]),
      ),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('document-start-date-filter-field')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('document-start-date-filter-field')),
      '2026-07-01',
    );
    await tester.enterText(
      find.byKey(const Key('document-end-date-filter-field')),
      '2026-07-31',
    );
    await tester.pump();

    expect(find.text('RK20260702001 · 矿泉水 550ml x5'), findsOneWidget);
    expect(find.text('XS20260630001 · 矿泉水 550ml x3'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('document-start-date-filter-field')),
      'invalid',
    );
    await tester.pump();

    expect(find.text('日期格式应为 YYYY-MM-DD'), findsOneWidget);
    expect(find.text('RK20260702001 · 矿泉水 550ml x5'), findsOneWidget);
    expect(find.text('XS20260630001 · 矿泉水 550ml x3'), findsNothing);
  });

  testWidgets('DocumentsPage retries recent documents after an error', (
    tester,
  ) async {
    final repository = _RetryDocumentsRepository();
    final viewModel = DocumentsViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('单据列表加载失败'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('单据列表加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.ensureVisible(find.text('重试'));
    await tester.pump();
    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(find.text('正在加载单据...'), findsOneWidget);

    repository.completeRetryDocuments();
    await tester.pumpAndSettle();

    expect(repository.listCallCount, 2);
    expect(find.text('单据列表加载失败'), findsNothing);
    expect(find.text('销售出库'), findsWidgets);
  });

  testWidgets('DocumentsPage retries transactions after an error', (
    tester,
  ) async {
    final repository = _RetryTransactionsRepository();
    final viewModel = DocumentsViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DocumentsPage(viewModel: viewModel)),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('流水加载失败'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('流水加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.ensureVisible(find.text('重试'));
    await tester.pump();
    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(find.text('正在加载流水...'), findsOneWidget);

    repository.completeRetryTransactions();
    await tester.pumpAndSettle();

    expect(repository.transactionCallCount, 2);
    expect(find.text('流水加载失败'), findsNothing);
    expect(find.text('销售单 · SO-20260626-001'), findsOneWidget);
  });

  test('documents and transactions expose independent page state', () async {
    final repository = _PagedDocumentsRepository(
      documentResults: [
        Success(_documentPage([_remoteDocument], total: 21)),
      ],
      transactionResults: [
        Success(_transactionPage([_transactionRecord], total: 12)),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.documentTotal, 21);
    expect(viewModel.hasMoreDocuments, isTrue);
    expect(viewModel.transactionTotal, 12);
    expect(viewModel.hasMoreTransactions, isTrue);
    expect(repository.documentPages, [1]);
    expect(repository.transactionPages, [1]);
  });

  test(
    'loading more documents appends by ID without reloading transactions',
    () async {
      const updatedDocument = DocumentRecord(
        id: 1,
        docType: 2,
        title: '销售出库',
        number: 'SO-20260626-001',
        status: '已完成',
      );
      final repository = _PagedDocumentsRepository(
        documentResults: [
          Success(_documentPage([_remoteDocument], total: 21)),
          Success(
            _documentPage(
              [updatedDocument, _completedInboundDocument],
              total: 21,
              page: 2,
            ),
          ),
        ],
        transactionResults: [Success(_transactionPage([]))],
      );
      final viewModel = DocumentsViewModel(repository: repository);
      await viewModel.load();

      await viewModel.loadMoreDocuments();

      expect(viewModel.recentDocuments, [
        updatedDocument,
        _completedInboundDocument,
      ]);
      expect(repository.documentPages, [1, 2]);
      expect(repository.transactionPages, [1]);
    },
  );

  test(
    'transaction load-more failure retries same page independently',
    () async {
      final repository = _PagedDocumentsRepository(
        documentResults: [
          Success(_documentPage([_remoteDocument])),
        ],
        transactionResults: [
          Success(_transactionPage([_transactionRecord], total: 12)),
          const FailureResult<PageData<TransactionRecord>>(
            NetworkFailure(message: '下一页流水失败'),
          ),
          Success(_transactionPage([], total: 12, page: 2)),
        ],
      );
      final viewModel = DocumentsViewModel(repository: repository);
      await viewModel.load();

      await viewModel.loadMoreTransactions();
      expect(viewModel.transactions, [_transactionRecord]);
      expect(viewModel.transactionLoadMoreFailure?.message, '下一页流水失败');
      await viewModel.retryLoadMoreTransactions();

      expect(repository.transactionPages, [1, 2, 2]);
      expect(repository.documentPages, [1]);
      expect(viewModel.hasMoreTransactions, isFalse);
    },
  );

  test('document type filter resets only the document stream', () async {
    final repository = _PagedDocumentsRepository(
      documentResults: [
        Success(_documentPage([_remoteDocument], total: 21)),
        Success(_documentPage([_completedInboundDocument])),
      ],
      transactionResults: [
        Success(_transactionPage([_transactionRecord])),
      ],
    );
    final viewModel = DocumentsViewModel(repository: repository);
    await viewModel.load();

    viewModel.selectDocumentTypeFilter(1);
    await repository.waitForDocumentCalls(2);

    expect(repository.documentPages, [1, 1]);
    expect(repository.documentTypes, [null, 1]);
    expect(repository.transactionPages, [1]);
  });

  test('return source lookup traverses every sales document page', () async {
    final repository = _PagedDocumentsRepository(
      documentResults: [
        Success(_documentPage([_draftSalesDocument], total: 11)),
        Success(_documentPage([_completedSalesDocument], total: 11, page: 2)),
      ],
      transactionResults: const [],
    );
    final viewModel = DocumentsViewModel(repository: repository)
      ..selectActionByLabel('退货入库');

    await viewModel.loadReturnSourceDocuments();

    expect(viewModel.returnSourceDocuments, [_completedSalesDocument]);
    expect(repository.documentPages, [1, 2]);
    expect(repository.documentTypes, [2, 2]);
  });

  test('creation refreshes authoritative document page one', () async {
    final repository = _FakeDocumentsRepository(
      listResults: const [
        Success<List<DocumentRecord>>([_remoteDocument]),
        Success<List<DocumentRecord>>([_completedInboundDocument]),
      ],
    );
    final viewModel = DocumentsViewModel(
      repository: repository,
      inventoryRepository: _FakeInventoryRepository(),
    )..updateQuantity('3');
    await viewModel.load();
    await viewModel.searchProducts('矿泉水');
    viewModel.selectProduct(_standardItem);

    expect(await viewModel.createDocument(), isTrue);

    expect(repository.listCallCount, 2);
    expect(viewModel.recentDocuments, [_completedInboundDocument]);
  });
}

DocumentsViewModel _draftEnabledViewModel({
  required DocumentDraftRepository drafts,
  DocumentsRepository? documents,
  InventoryRepository? inventory,
  OutboxRepository? outbox,
  OutboxAttachmentStagingStore? submissionStagingStore,
  String roleCode = 'operator',
  String Function()? draftIdFactory,
  Set<OutboxOperationKind> allowedOutboxKinds = const {
    ...OutboxOperationKind.values,
  },
}) => DocumentsViewModel(
  repository: documents,
  inventoryRepository: inventory,
  draftRepository: drafts,
  accountId: '7',
  outboxRepository: outbox,
  submissionStagingStore: submissionStagingStore,
  observedRoleCode: roleCode,
  allowedOutboxKinds: allowedOutboxKinds,
  currentWarehouse: const Warehouse(
    id: 11,
    code: 'MAIN',
    name: 'Main',
    isDefault: true,
  ),
  draftIdFactory:
      draftIdFactory ?? () => 'draft-${DateTime.now().microsecondsSinceEpoch}',
);

final class _OutboxSubmissionStagingStore
    implements OutboxAttachmentStagingStore {
  @override
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) async => Success(
    StagedAttachment(
      pending: PendingAttachment(
        requestId: requestId,
        binding: AttachmentBinding.documentDraft('draft-1'),
        stagedPath: 'owned/$requestId.pdf',
        originalName: 'proof.pdf',
        mimeType: 'application/pdf',
        fileSize: 3,
      ),
      thumbnailPath: null,
      createdAt: DateTime.utc(2026, 7, 13),
      sha256: 'stable-hash',
    ),
  );

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) async => const Success(null);

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async => const Success(null);
}

final class _DocumentSubmitAdapter implements HttpClientAdapter {
  const _DocumentSubmitAdapter({
    this.body =
        '{"code":0,"message":"ok","data":{"id":91,"docNo":"DOC-91","docType":2,"docTypeName":"销售出库","statusName":"草稿"}}',
    this.throwUnknownTransport = false,
    this.throwType,
  });

  final String body;
  final bool throwUnknownTransport;
  final DioExceptionType? throwType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (throwType case final type?) {
      await requestStream?.drain<void>();
      throw DioException(requestOptions: options, type: type);
    }
    if (throwUnknownTransport) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: const SocketException('response boundary lost'),
      );
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

extension _SuccessData<T> on Result<T> {
  T get successData => switch (this) {
    Success<T>(:final data) => data,
    FailureResult<T>(:final failure) => throw TestFailure(failure.message),
  };
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw TestFailure('Condition was not reached.');
}

DocumentDraft _savedDraft(
  String id, {
  String remark = '',
  int docType = 2,
  String observedRoleCode = 'operator',
}) {
  final now = DateTime.utc(2026, 7, 13);
  return DocumentDraft(
    id: id,
    accountId: '7',
    warehouseId: 11,
    docType: docType,
    observedRoleCode: observedRoleCode,
    payload: {
      'lines': [
        {
          'product_id': 10,
          'product_name': '标准商品',
          'quantity': 2,
          'retail_price': 12.5,
        },
      ],
      'remark': remark,
    },
    createdAt: now,
    updatedAt: now,
    version: 1,
  );
}

DocumentDraft _returnDraft(String id, {required int sourceDocumentId}) {
  final timestamp = DateTime.utc(2026, 7, 13);
  return DocumentDraft(
    id: id,
    accountId: '7',
    warehouseId: 11,
    docType: 3,
    observedRoleCode: 'operator',
    payload: {
      'lines': [
        {
          'product_id': 10,
          'product_name': _completedSalesDocument.productName,
          'quantity': 1,
        },
      ],
      'source_document_id': sourceDocumentId,
      'remark': '',
    },
    createdAt: timestamp,
    updatedAt: timestamp,
    version: 1,
  );
}

final class _FakeDocumentDraftRepository implements DocumentDraftRepository {
  _FakeDocumentDraftRepository({this.loaded, this.saveResults = const []});

  final DocumentDraft? loaded;
  final List<Future<Result<DocumentDraft>>> saveResults;
  final List<DocumentDraft> saved = [];
  final List<(String, String)> deleted = [];
  int saveCallCount = 0;

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
    saved.add(draft);
    final index = saveCallCount++;
    if (index < saveResults.length) return saveResults[index];
    return Success(draft.copyWith(version: expectedVersion + 1));
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async =>
      loaded?.accountId == accountId && loaded?.id == draftId ? loaded : null;

  @override
  Future<List<DocumentDraft>> list(String accountId) async => const [];

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deleted.add((accountId, draftId));
  }

  @override
  Future<void> prune() async {}
}

final class _ControlledDraftRepository implements DocumentDraftRepository {
  final List<(DocumentDraft, int, Completer<Result<DocumentDraft>>)> _pending =
      [];
  final Map<String, DocumentDraft> _persisted = {};
  final List<(String, String)> deleted = [];
  int saveCallCount = 0;

  Iterable<String> get persistedDraftIds => _persisted.keys;
  Iterable<String> get pendingDraftIds => _pending.map((item) => item.$1.id);
  Iterable<int> get pendingExpectedVersions => _pending.map((item) => item.$2);

  void seed(DocumentDraft draft) => _persisted[draft.id] = draft;

  void completeNextSave({int? version}) {
    final pending = _pending.removeAt(0);
    final saved = pending.$1.copyWith(version: version ?? pending.$2 + 1);
    pending.$3.complete(Success(saved));
  }

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
    saveCallCount += 1;
    final completer = Completer<Result<DocumentDraft>>();
    _pending.add((draft, expectedVersion, completer));
    final result = await completer.future;
    result.when(
      success: (saved) => _persisted[saved.id] = saved,
      failure: (_) {},
    );
    return result;
  }

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deleted.add((accountId, draftId));
    _persisted.remove(draftId);
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async => _persisted[draftId];

  @override
  Future<List<DocumentDraft>> list(String accountId) async => _persisted.values
      .where((draft) => draft.accountId == accountId)
      .toList(growable: false);

  @override
  Future<void> prune() async {}
}

final class _OutOfOrderOpenDraftRepository implements DocumentDraftRepository {
  final Map<String, Completer<DocumentDraft?>> _loads = {};

  void complete(String draftId, DocumentDraft? draft) {
    (_loads[draftId] ??= Completer<DocumentDraft?>()).complete(draft);
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) => (_loads[draftId] ??= Completer<DocumentDraft?>()).future;

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async => Success(draft);

  @override
  Future<List<DocumentDraft>> list(String accountId) async => const [];

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {}

  @override
  Future<void> prune() async {}
}

final class _PageDraftPicker implements AttachmentPicker {
  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async => const Success(
    SelectedAttachmentSource(
      path: '/source/file.pdf',
      originalName: 'file.pdf',
      mimeType: 'application/pdf',
      fileSize: 12,
    ),
  );

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);

  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];
}

final class _PageDraftStaging implements AttachmentStagingStore {
  _PageDraftStaging({Future<Result<void>>? removeResult})
    : removeResult = removeResult ?? Future.value(const Success(null));

  final Future<Result<void>> removeResult;
  final List<AttachmentBinding> bindings = [];
  final List<StagedAttachment> items = [];
  final Completer<void> removeStarted = Completer<void>();

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) async {
    bindings.add(binding);
    final item = StagedAttachment(
      pending: PendingAttachment(
        requestId: 'ui-request',
        binding: binding,
        stagedPath: '/staged/ui-request',
        originalName: selection.originalName,
        mimeType: selection.mimeType,
        fileSize: selection.fileSize,
      ),
      thumbnailPath: null,
      createdAt: DateTime.utc(2026, 7, 13),
    );
    items.add(item);
    return Success(item);
  }

  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async =>
      Success(items);

  @override
  Future<Result<void>> remove(String userId, String requestId) async {
    if (!removeStarted.isCompleted) removeStarted.complete();
    final result = await removeResult;
    if (result case Success<void>()) {
      items.removeWhere((item) => item.pending.requestId == requestId);
    }
    return result;
  }

  @override
  Future<Result<void>> cleanupStale({
    required String userId,
    required Duration maxAge,
    Set<String> protectedRequestIds = const {},
  }) async => const Success(null);

  @override
  Future<Result<void>> clearForUser(String userId) async => const Success(null);

  @override
  Future<Result<String>> saveDownload({
    required String userId,
    required String originalName,
    required Uint8List bytes,
  }) async => const Success('/download');
}

StagedAttachment _pageStaged(String requestId, String draftId) =>
    StagedAttachment(
      pending: PendingAttachment(
        requestId: requestId,
        binding: AttachmentBinding.documentDraft(draftId),
        stagedPath: '/staged/$requestId',
        originalName: '$requestId.pdf',
        mimeType: 'application/pdf',
        fileSize: 12,
      ),
      thumbnailPath: null,
      createdAt: DateTime.utc(2026, 7, 13),
    );

const _remoteDocument = DocumentRecord(
  id: 1,
  docType: 2,
  title: '销售出库',
  number: 'SO-20260626-001',
  status: '待提交',
  productName: '矿泉水 550ml',
  quantity: 3,
);

const _completedRemoteDocument = DocumentRecord(
  id: 1,
  docType: 2,
  title: '销售出库',
  number: 'SO-20260626-001',
  status: '已完成',
  productName: '矿泉水 550ml',
  quantity: 3,
);

const _createdHeaderOnlyDocument = DocumentRecord(
  id: 700,
  docType: 2,
  title: '销售单',
  number: 'XS20260706005',
  status: '草稿',
);

const _transactionRecord = TransactionRecord(
  id: 21,
  warehouseId: 1,
  productId: 10,
  docId: 1,
  docNo: 'SO-20260626-001',
  docType: 2,
  docTypeName: '销售单',
  direction: -1,
  quantity: 3,
  beforeQty: 12,
  afterQty: 9,
  operatorId: 5,
  operatedAt: '2026-06-27T10:30:00Z',
  createdAt: '2026-06-27T10:30:00Z',
);

const _completedSalesDocument = DocumentRecord(
  id: 136,
  docType: 2,
  title: '销售单',
  number: 'XS20260417035',
  status: '已完成',
  productName: '矿泉水 550ml',
  quantity: 3,
);

const _draftSalesDocument = DocumentRecord(
  id: 137,
  docType: 2,
  title: '销售单',
  number: 'XS20260417036',
  status: '待提交',
);

const _draftTransferDocument = DocumentRecord(
  id: 701,
  docType: 4,
  title: '调拨单',
  number: 'DB20260706001',
  status: '待提交',
);

const _draftConversionDocument = DocumentRecord(
  id: 702,
  docType: 6,
  title: '转标准',
  number: 'BZ20260706001',
  status: '待提交',
);

const _completedDraftSalesDocument = DocumentRecord(
  id: 137,
  docType: 2,
  title: '销售单',
  number: 'XS20260417036',
  status: '已完成',
);

const _completedInboundDocument = DocumentRecord(
  id: 138,
  docType: 1,
  title: '入库单',
  number: 'RK20260417001',
  status: '已完成',
);

const _completedStocktakeDocument = DocumentRecord(
  id: 502,
  docType: 5,
  title: '盘点单',
  number: 'PD20260627002',
  status: '已完成',
  productName: '低库存商品',
  quantity: 2,
);

const _julyInboundDocument = DocumentRecord(
  id: 601,
  docType: 1,
  title: '入库单',
  number: 'RK20260702001',
  status: '已完成',
  productName: '矿泉水 550ml',
  quantity: 5,
  createdAt: '2026-07-02T10:15:00Z',
);

const _juneSalesDocument = DocumentRecord(
  id: 602,
  docType: 2,
  title: '销售单',
  number: 'XS20260630001',
  status: '已完成',
  productName: '矿泉水 550ml',
  quantity: 3,
  createdAt: '2026-06-30T18:30:00Z',
);

const _undatedDocument = DocumentRecord(
  id: 603,
  docType: 4,
  title: '调拨单',
  number: 'DB20260701001',
  status: '待提交',
);

const _countingStocktakeDocument = DocumentRecord(
  id: 501,
  docType: 5,
  title: '盘点单',
  number: 'PD20260627001',
  status: '盘点中',
);

const _confirmedStocktakeDocument = DocumentRecord(
  id: 501,
  docType: 5,
  title: '盘点单',
  number: 'PD20260627001',
  status: '差异已确认',
);

const _settledStocktakeDocument = DocumentRecord(
  id: 501,
  docType: 5,
  title: '盘点单',
  number: 'PD20260627001',
  status: '已结转',
);

const _standardItem = InventoryItem(
  id: 1,
  productId: 10,
  productName: '矿泉水 550ml',
  sku: 'SKU-WA-550',
  availableQuantity: 128,
  stockQuantity: 150,
  statusLabel: '标准',
  imageUrl: '',
  retailPrice: 6.5,
);

const _staleItem = InventoryItem(
  id: 2,
  productId: 20,
  productName: '旧商品',
  sku: 'SKU-OLD',
  availableQuantity: 4,
  stockQuantity: 4,
  statusLabel: '标准',
  imageUrl: '',
);

const _nonStandardItem = NonStandardInventoryItem(
  id: 11,
  tempLabel: 'TMP-20260627-001',
  description: '破损瓶临时集合',
  unit: '件',
  quantity: 5,
  convertedQuantity: 1,
  remainingQuantity: 4,
  status: 1,
);

const _secondNonStandardItem = NonStandardInventoryItem(
  id: 12,
  tempLabel: 'TMP-20260627-002',
  description: '第二页临时集合',
  unit: '件',
  quantity: 3,
  convertedQuantity: 0,
  remainingQuantity: 3,
  status: 1,
);

const _shanghaiWarehouse = Warehouse(
  id: 1,
  code: 'SH',
  name: '上海仓',
  isDefault: true,
);

const _beijingWarehouse = Warehouse(
  id: 2,
  code: 'BJ',
  name: '北京仓',
  isDefault: false,
);

final class _FakeDocumentsRepository
    implements DocumentsRepository, DocumentDetailsRepository {
  _FakeDocumentsRepository({
    this.listResult = const Success<List<DocumentRecord>>([_remoteDocument]),
    this.listResults = const [],
    Future<Result<DocumentRecord>>? createResult,
    Future<Result<void>>? completeResult,
    this.confirmResult = const Success<void>(null),
    this.settleResult = const Success<void>(null),
    this.transactionResult = const Success<List<TransactionRecord>>([
      _transactionRecord,
    ]),
    this.transactionResults = const [],
    this.listFuture,
  }) : createResult =
           createResult ??
           Future.value(const Success<DocumentRecord>(_remoteDocument)),
       completeResult =
           completeResult ?? Future.value(const Success<void>(null));

  final Result<List<DocumentRecord>> listResult;
  final List<Result<List<DocumentRecord>>> listResults;
  final Future<Result<DocumentRecord>> createResult;
  final Future<Result<void>> completeResult;
  final Result<void> confirmResult;
  final Result<void> settleResult;
  final Result<List<TransactionRecord>> transactionResult;
  final List<Result<List<TransactionRecord>>> transactionResults;
  final Future<Result<List<DocumentRecord>>>? listFuture;
  CreateDocumentRequest? createdRequest;
  final List<String> createdRequestIds = [];
  final List<String> completedRequestIds = [];
  int createCallCount = 0;
  int completeCallCount = 0;
  int? completedDocumentId;
  int? confirmedDocumentId;
  int? settledDocumentId;
  final List<String> settledRequestIds = [];
  int? detailDocumentId;
  int listCallCount = 0;
  int _transactionResultCallCount = 0;
  int? lastListDocType;
  final List<int?> listDocTypes = [];

  @override
  Future<Result<DocumentDetail>> getDocument(int id) async {
    detailDocumentId = id;
    return Success(
      DocumentDetail(
        record: _remoteDocument,
        lines: const [
          DocumentLine(
            id: 501,
            productId: 10,
            nonStandardInventoryId: 0,
            productCode: 'SKU-AUTH-1',
            productName: '权威明细商品',
            quantity: 4,
            unit: '箱',
            costPrice: 0,
            retailPrice: 12,
            systemQuantity: 0,
            actualQuantity: 0,
            differenceQuantity: 0,
            remark: '',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    lastListDocType = docType;
    listDocTypes.add(docType);
    final callIndex = listCallCount;
    listCallCount += 1;
    final delayed = listFuture;
    if (delayed != null) {
      return _pageResult(await delayed, page: page);
    }
    if (callIndex < listResults.length) {
      return _pageResult(listResults[callIndex], page: page);
    }

    return _pageResult(listResult, page: page);
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    createCallCount += 1;
    createdRequest = request;
    createdRequestIds.add(request.requestId);
    return createResult;
  }

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async {
    completeCallCount += 1;
    completedDocumentId = id;
    completedRequestIds.add(requestId ?? '');
    return completeResult;
  }

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async {
    confirmedDocumentId = id;
    return confirmResult;
  }

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async {
    settledDocumentId = id;
    settledRequestIds.add(requestId ?? '');
    return settleResult;
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    final callIndex = _transactionResultCallCount;
    _transactionResultCallCount += 1;
    if (callIndex < transactionResults.length) {
      return _pageResult(transactionResults[callIndex], page: page);
    }

    return _pageResult(transactionResult, page: page);
  }
}

final class _RetryDocumentsRepository implements DocumentsRepository {
  int listCallCount = 0;
  int transactionCallCount = 0;
  Completer<List<DocumentRecord>>? _retryDocumentsCompleter;

  void completeRetryDocuments() {
    _retryDocumentsCompleter?.complete([_remoteDocument]);
  }

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    listCallCount += 1;
    if (listCallCount == 1) {
      return const FailureResult<PageData<DocumentRecord>>(
        NetworkFailure(message: '单据列表加载失败'),
      );
    }

    _retryDocumentsCompleter = Completer<List<DocumentRecord>>();
    return Success<PageData<DocumentRecord>>(
      _documentPage(await _retryDocumentsCompleter!.future, page: page),
    );
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    transactionCallCount += 1;
    return Success(_transactionPage([_transactionRecord], page: page));
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(_remoteDocument);
  }

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async {
    return const Success<void>(null);
  }
}

final class _DelayedCreationRefreshRepository implements DocumentsRepository {
  final Completer<Result<PageData<DocumentRecord>>> _refreshCompleter =
      Completer<Result<PageData<DocumentRecord>>>();
  int listCallCount = 0;

  Future<void> waitForRefreshCall() async {
    while (listCallCount < 2) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void completeRefresh() {
    _refreshCompleter.complete(Success(_documentPage([_remoteDocument])));
  }

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    listCallCount += 1;
    if (listCallCount == 1) {
      return Success(_documentPage([_remoteDocument], page: page));
    }
    return _refreshCompleter.future;
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async => const Success(_remoteDocument);

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async => Success(_transactionPage([], page: page));

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async =>
      const Success<void>(null);
}

final class _RetryTransactionsRepository extends _FakeDocumentsRepository {
  int transactionCallCount = 0;
  Completer<List<TransactionRecord>>? _retryTransactionsCompleter;

  void completeRetryTransactions() {
    _retryTransactionsCompleter?.complete([_transactionRecord]);
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    transactionCallCount += 1;
    if (transactionCallCount == 1) {
      return const FailureResult<PageData<TransactionRecord>>(
        NetworkFailure(message: '流水加载失败'),
      );
    }

    _retryTransactionsCompleter = Completer<List<TransactionRecord>>();
    return Success<PageData<TransactionRecord>>(
      _transactionPage(await _retryTransactionsCompleter!.future, page: page),
    );
  }
}

final class _PagedDocumentsRepository implements DocumentsRepository {
  _PagedDocumentsRepository({
    required this.documentResults,
    required this.transactionResults,
  });

  final List<Result<PageData<DocumentRecord>>> documentResults;
  final List<Result<PageData<TransactionRecord>>> transactionResults;
  final List<int> documentPages = [];
  final List<int?> documentTypes = [];
  final List<int> transactionPages = [];
  int _documentIndex = 0;
  int _transactionIndex = 0;

  Future<void> waitForDocumentCalls(int count) async {
    while (documentPages.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) async {
    documentPages.add(page);
    documentTypes.add(docType);
    final result = documentResults[_documentIndex];
    _documentIndex += 1;
    return result;
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) async {
    transactionPages.add(page);
    final result = transactionResults[_transactionIndex];
    _transactionIndex += 1;
    return result;
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async => const Success(_remoteDocument);

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async =>
      const Success<void>(null);
}

Result<PageData<T>> _pageResult<T>(Result<List<T>> result, {int page = 1}) {
  return result.when(
    success: (items) => Success(
      PageData(items: items, total: items.length, page: page, pageSize: 10),
    ),
    failure: FailureResult<PageData<T>>.new,
  );
}

PageData<DocumentRecord> _documentPage(
  List<DocumentRecord> items, {
  int? total,
  int page = 1,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: 10,
  );
}

PageData<TransactionRecord> _transactionPage(
  List<TransactionRecord> items, {
  int? total,
  int page = 1,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: 10,
  );
}

PageData<InventoryItem> _inventoryPage(List<InventoryItem> items) {
  return PageData(items: items, total: items.length, page: 1, pageSize: 20);
}

PageData<NonStandardInventoryItem> _nonStandardPage(
  List<NonStandardInventoryItem> items, {
  int? total,
  int page = 1,
  int pageSize = 20,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: pageSize,
  );
}

final class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository({
    this.inventorySearchResults = const [],
    this.nonStandardInventoryResults = const [],
  });

  final List<Future<Result<PageData<InventoryItem>>>> inventorySearchResults;
  final List<Result<PageData<NonStandardInventoryItem>>>
  nonStandardInventoryResults;
  final List<String> inventoryKeywords = [];
  String? lastKeyword;
  bool loadedNonStandardInventory = false;
  int inventorySearchCallCount = 0;
  int nonStandardInventoryCallCount = 0;
  final List<int> nonStandardInventoryPages = [];

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    lastKeyword = keyword;
    inventoryKeywords.add(keyword);
    final callIndex = inventorySearchCallCount;
    inventorySearchCallCount += 1;
    if (callIndex < inventorySearchResults.length) {
      return inventorySearchResults[callIndex];
    }

    return Success(_inventoryPage([_standardItem]));
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_inventoryPage([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success<InventoryItem>(_standardItem);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    loadedNonStandardInventory = true;
    nonStandardInventoryPages.add(page);
    final callIndex = nonStandardInventoryCallCount;
    nonStandardInventoryCallCount += 1;
    if (callIndex < nonStandardInventoryResults.length) {
      return nonStandardInventoryResults[callIndex];
    }

    return Success(_nonStandardPage([_nonStandardItem]));
  }
}
