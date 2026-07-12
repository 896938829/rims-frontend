import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/documents/presentation/pages/documents_page.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';

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

DocumentDraft _savedDraft(String id, {String remark = ''}) {
  final now = DateTime.utc(2026, 7, 13);
  return DocumentDraft(
    id: id,
    accountId: '7',
    warehouseId: 11,
    docType: 2,
    observedRoleCode: 'operator',
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
  CreateDocumentRequest? createdRequest;
  final List<String> createdRequestIds = [];
  int createCallCount = 0;
  int completeCallCount = 0;
  int? completedDocumentId;
  int? confirmedDocumentId;
  int? settledDocumentId;
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
  Future<Result<void>> completeDocument(int id) async {
    completeCallCount += 1;
    completedDocumentId = id;
    return completeResult;
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    confirmedDocumentId = id;
    return confirmResult;
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    settledDocumentId = id;
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
  Future<Result<void>> completeDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
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
  Future<Result<void>> completeDocument(int id) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> confirmDocument(int id) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> settleDocument(int id) async =>
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
  Future<Result<void>> completeDocument(int id) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> confirmDocument(int id) async =>
      const Success<void>(null);

  @override
  Future<Result<void>> settleDocument(int id) async =>
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
