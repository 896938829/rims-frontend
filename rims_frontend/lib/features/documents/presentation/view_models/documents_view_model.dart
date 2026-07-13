import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/result/result.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/resources/app_icons.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/entities/non_standard_inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../offline/domain/entities/document_draft.dart';
import '../../../offline/domain/entities/outbox_operation.dart';
import '../../../offline/domain/entities/outbox_graph.dart';
import '../../../offline/domain/repositories/document_draft_repository.dart';
import '../../../offline/domain/repositories/outbox_repository.dart';

final class DocumentAction {
  const DocumentAction({
    required this.label,
    required this.docType,
    required this.iconPath,
  });

  final String label;
  final int docType;
  final String iconPath;
}

final class _PendingOfflineSubmission {
  const _PendingOfflineSubmission({
    required this.request,
    required this.accountId,
    required this.warehouseId,
    required this.localAggregateId,
    required this.attachmentRequestIds,
    required this.requiresStatusProbe,
    required this.review,
  });

  final CreateDocumentRequest request;
  final String accountId;
  final int warehouseId;
  final String localAggregateId;
  final List<String> attachmentRequestIds;
  final bool requiresStatusProbe;
  final OfflineSubmissionReview review;
}

final class _PendingLifecycleSubmission {
  const _PendingLifecycleSubmission({
    required this.kind,
    required this.requestId,
    required this.documentId,
    required this.accountId,
    required this.warehouseId,
    required this.requiresStatusProbe,
    required this.review,
  });

  final OutboxOperationKind kind;
  final String requestId;
  final int documentId;
  final String accountId;
  final int warehouseId;
  final bool requiresStatusProbe;
  final OfflineSubmissionReview review;
}

final class OfflineSubmissionReview {
  OfflineSubmissionReview({
    required this.warehouseName,
    required this.documentType,
    required this.lineCount,
    required List<String> lines,
    required List<String> staleAssumptions,
  }) : lines = List.unmodifiable(lines),
       staleAssumptions = List.unmodifiable(staleAssumptions);

  final String warehouseName;
  final String documentType;
  final int lineCount;
  final List<String> lines;
  final List<String> staleAssumptions;
}

final class DocumentsViewModel extends ChangeNotifier {
  DocumentsViewModel({
    this.repository,
    this.inventoryRepository,
    this.currentWarehouse,
    this.warehouses = const [],
    this.canManageAdminDocumentActions = true,
    this.draftRepository,
    this.outboxRepository,
    this.submissionStagingStore,
    this.accountId,
    this.observedRoleCode = '',
    String Function()? draftIdFactory,
    DateTime Function()? now,
    this.autosaveDelay = const Duration(milliseconds: 300),
  }) : _selectedAction = _actions.first,
       _recentDocuments = const [],
       _transactions = const [],
       draftIdFactory = draftIdFactory ?? const Uuid().v4,
       now = now ?? DateTime.now;

  static const List<DocumentAction> _actions = [
    DocumentAction(label: '销售出库', docType: 2, iconPath: AppIcons.actionInbound),
    DocumentAction(label: '采购入库', docType: 1, iconPath: AppIcons.actionReport),
    DocumentAction(label: '调拨单', docType: 4, iconPath: AppIcons.actionTransfer),
    DocumentAction(label: '退货入库', docType: 3, iconPath: AppIcons.actionReturn),
    DocumentAction(
      label: '盘点单',
      docType: 5,
      iconPath: AppIcons.actionStocktake,
    ),
    DocumentAction(label: '转标准', docType: 6, iconPath: AppIcons.actionScan),
  ];

  final DocumentsRepository? repository;
  final InventoryRepository? inventoryRepository;
  final Warehouse? currentWarehouse;
  final List<Warehouse> warehouses;
  final bool canManageAdminDocumentActions;
  final DocumentDraftRepository? draftRepository;
  final OutboxRepository? outboxRepository;
  final OutboxAttachmentStagingStore? submissionStagingStore;
  final String? accountId;
  final String observedRoleCode;
  final String Function() draftIdFactory;
  final DateTime Function() now;
  final Duration autosaveDelay;
  List<DocumentRecord> _recentDocuments;
  List<TransactionRecord> _transactions;
  List<InventoryItem> _productCandidates = const [];
  List<NonStandardInventoryItem> _nonStandardInventoryItems = const [];
  List<DocumentRecord> _returnSourceDocuments = const [];
  List<CreateDocumentLineRequest> _draftLines = const [];
  String? _draftRequestId;
  Set<int> _completingDocumentIds = const {};
  DocumentAction _selectedAction;
  InventoryItem? _selectedProduct;
  NonStandardInventoryItem? _selectedNonStandardInventory;
  Warehouse? _selectedTargetWarehouse;
  DocumentRecord? _selectedReturnSourceDocument;
  int? _pendingReturnSourceDocumentId;
  String _productQuery = '';
  String _documentKeyword = '';
  String _quantityText = '';
  String _remark = '';
  DateTime? _documentStartDate;
  DateTime? _documentEndDate;
  int? _selectedDocumentTypeFilter;
  String? _selectedDocumentStatusFilter;
  String? _formError;
  String? _errorMessage;
  String? _transactionError;
  String? _documentActionError;
  String? _productSearchError;
  String? _nonStandardInventoryError;
  String? _returnSourceError;
  int _productSearchRequestId = 0;
  bool _isLoading = false;
  bool _isSearchingProducts = false;
  bool _isLoadingNonStandardInventory = false;
  bool _isLoadingReturnSources = false;
  bool _hasLoadedReturnSourceDocuments = false;
  bool _isSubmitting = false;
  bool _isAttachmentMutationInProgress = false;
  int _documentPage = 0;
  int _documentTotal = 0;
  int _documentGeneration = 0;
  bool _isLoadingMoreDocuments = false;
  bool _documentsReachedEnd = false;
  Failure? _documentLoadMoreFailure;
  int _transactionPage = 0;
  int _transactionTotal = 0;
  int _transactionGeneration = 0;
  bool _isLoadingMoreTransactions = false;
  bool _transactionsReachedEnd = false;
  Failure? _transactionLoadMoreFailure;
  bool _isDisposed = false;
  DocumentReadStatus? _readStatus;
  Timer? _draftSaveTimer;
  Future<void>? _draftSaveInFlight;
  bool _draftDirty = false;
  bool _draftSubmissionBarrier = false;
  int _submissionEpoch = 0;
  int _draftContextGeneration = 0;
  int _draftOpenGeneration = 0;
  String? _activeDraftId;
  DateTime? _draftCreatedAt;
  int _draftVersion = 0;
  String? _draftSaveError;
  List<String> _attachmentStagingIds = const [];
  int? _nonStandardSourceId;
  bool _requiresDraftReview = false;
  String? _draftObservedRoleCode;
  _PendingOfflineSubmission? _pendingOfflineSubmission;
  _PendingLifecycleSubmission? _pendingLifecycleSubmission;
  bool _offlineEnqueueInFlight = false;
  final Map<String, String> _lifecycleRequestIds = {};

  @override
  void dispose() {
    _isDisposed = true;
    _draftSaveTimer?.cancel();
    super.dispose();
  }

  List<DocumentAction> get actions => _actions
      .where(
        (action) =>
            canManageAdminDocumentActions || !_isAdminOnlyAction(action),
      )
      .toList(growable: false);
  List<String> get flowSteps => const ['创建', '确认', '提交', '完成'];
  OfflineSubmissionReview? get offlineSubmissionReview =>
      _pendingOfflineSubmission?.review ?? _pendingLifecycleSubmission?.review;
  List<DocumentRecord> get recentDocuments =>
      List<DocumentRecord>.unmodifiable(_recentDocuments);
  List<DocumentRecord> get visibleDocuments {
    final normalizedKeyword = _documentKeyword.trim().toLowerCase();
    return _recentDocuments
        .where((document) {
          final matchesType =
              _selectedDocumentTypeFilter == null ||
              document.docType == _selectedDocumentTypeFilter;
          final matchesStatus =
              _selectedDocumentStatusFilter == null ||
              document.status == _selectedDocumentStatusFilter;
          final matchesKeyword =
              normalizedKeyword.isEmpty ||
              document.title.toLowerCase().contains(normalizedKeyword) ||
              document.number.toLowerCase().contains(normalizedKeyword) ||
              document.status.toLowerCase().contains(normalizedKeyword) ||
              document.productName.toLowerCase().contains(normalizedKeyword);
          final matchesDate = _matchesDocumentDate(document);

          return matchesType && matchesStatus && matchesKeyword && matchesDate;
        })
        .toList(growable: false);
  }

  List<String> get documentStatusFilters {
    return {
      for (final document in _recentDocuments)
        if (document.status.isNotEmpty) document.status,
    }.toList(growable: false);
  }

  List<TransactionRecord> get transactions =>
      List<TransactionRecord>.unmodifiable(_transactions);
  List<InventoryItem> get productCandidates =>
      List<InventoryItem>.unmodifiable(_productCandidates);
  List<NonStandardInventoryItem> get nonStandardInventoryItems =>
      List<NonStandardInventoryItem>.unmodifiable(_nonStandardInventoryItems);
  List<CreateDocumentLineRequest> get draftLines =>
      List.unmodifiable(_draftLines);
  List<Warehouse> get targetWarehouses => warehouses
      .where((warehouse) => warehouse.id != currentWarehouse?.id)
      .toList(growable: false);
  List<DocumentRecord> get returnSourceDocuments {
    final documents = _hasLoadedReturnSourceDocuments
        ? _returnSourceDocuments
        : _eligibleReturnSourceDocuments(_recentDocuments);
    return List<DocumentRecord>.unmodifiable(documents);
  }

  DocumentAction get selectedAction => _selectedAction;
  bool get isTransferAction => _selectedAction.docType == 4;
  bool get isReturnAction => _selectedAction.docType == 3;
  bool get isStocktakeAction => _selectedAction.docType == 5;
  bool get isConversionAction => _selectedAction.docType == 6;
  InventoryItem? get selectedProduct => _selectedProduct;
  NonStandardInventoryItem? get selectedNonStandardInventory =>
      _selectedNonStandardInventory;
  Warehouse? get selectedTargetWarehouse => _selectedTargetWarehouse;
  DocumentRecord? get selectedReturnSourceDocument =>
      _selectedReturnSourceDocument;
  int? get pendingReturnSourceDocumentId => _pendingReturnSourceDocumentId;
  String get productName => _selectedProduct?.productName ?? _productQuery;
  String get productQuery => _productQuery;
  String get documentKeyword => _documentKeyword;
  DateTime? get documentStartDate => _documentStartDate;
  DateTime? get documentEndDate => _documentEndDate;
  int? get selectedDocumentTypeFilter => _selectedDocumentTypeFilter;
  String? get selectedDocumentStatusFilter => _selectedDocumentStatusFilter;
  String get quantityText => _quantityText;
  String get remark => _remark;
  String? get formError => _formError;
  String? get errorMessage => _errorMessage;
  String? get transactionError => _transactionError;
  String? get documentActionError => _documentActionError;
  String? get productSearchError => _productSearchError;
  String? get nonStandardInventoryError => _nonStandardInventoryError;
  String? get returnSourceError => _returnSourceError;
  String? get activeDraftId => _activeDraftId;
  String? get draftSaveError => _draftSaveError;
  List<String> get attachmentStagingIds =>
      List.unmodifiable(_attachmentStagingIds);
  int? get nonStandardSourceId => _nonStandardSourceId;
  bool get requiresDraftReview => _requiresDraftReview;
  bool get isLoading => _isLoading;
  bool get isSearchingProducts => _isSearchingProducts;
  bool get isLoadingNonStandardInventory => _isLoadingNonStandardInventory;
  bool get isLoadingReturnSources => _isLoadingReturnSources;
  bool get isSubmitting => _isSubmitting;
  bool get isAttachmentMutationInProgress => _isAttachmentMutationInProgress;
  int get submissionEpoch => _submissionEpoch;
  int get documentTotal => _documentTotal;
  bool get hasMoreDocuments =>
      _documentPage > 0 &&
      !_documentsReachedEnd &&
      _recentDocuments.length < _documentTotal;
  bool get isLoadingMoreDocuments => _isLoadingMoreDocuments;
  Failure? get documentLoadMoreFailure => _documentLoadMoreFailure;
  int get transactionTotal => _transactionTotal;
  bool get hasMoreTransactions =>
      _transactionPage > 0 &&
      !_transactionsReachedEnd &&
      _transactions.length < _transactionTotal;
  bool get isLoadingMoreTransactions => _isLoadingMoreTransactions;
  Failure? get transactionLoadMoreFailure => _transactionLoadMoreFailure;
  DocumentReadStatus? get readStatus => _readStatus;
  String? get cacheStatusLabel => _readStatus?.isCached == true
      ? '离线缓存 · 更新于 ${_formatCacheTime(_readStatus!.fetchedAt)}'
      : null;
  String get quantityInputLabel => isStocktakeAction ? '实盘数量' : '数量';
  String get quantityInputHint => isStocktakeAction ? '输入实盘数量' : '输入数量';

  void selectAction(DocumentAction action) {
    if (!_canMutateDocumentForm) return;
    if (_isAdminOnlyAction(action) && !canManageAdminDocumentActions) {
      return;
    }

    _selectedAction = action;
    _draftLines = const [];
    _draftRequestId = null;
    _formError = null;
    if (!isTransferAction) {
      _selectedTargetWarehouse = null;
    }
    if (!isReturnAction) {
      _selectedReturnSourceDocument = null;
      _pendingReturnSourceDocumentId = null;
      _returnSourceDocuments = const [];
      _returnSourceError = null;
      _hasLoadedReturnSourceDocuments = false;
      _isLoadingReturnSources = false;
    }
    if (!isConversionAction) {
      _selectedNonStandardInventory = null;
      _nonStandardSourceId = null;
    }
    _scheduleDraftSave();
    notifyListeners();
  }

  void selectActionByLabel(String label) {
    selectAction(
      actions.firstWhere(
        (action) => action.label == label,
        orElse: () => _selectedAction,
      ),
    );
  }

  void updateProductName(String value) {
    if (!_canMutateDocumentForm) return;
    _productQuery = value;
    if (_selectedProduct?.productName != value) {
      _selectedProduct = null;
    }
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void selectDocumentTypeFilter(int? docType) {
    if (_selectedDocumentTypeFilter == docType) {
      return;
    }

    _selectedDocumentTypeFilter = docType;
    notifyListeners();
    unawaited(_loadDocumentsFirstPage());
  }

  void selectDocumentStatusFilter(String? status) {
    if (_selectedDocumentStatusFilter == status) {
      return;
    }

    _selectedDocumentStatusFilter = status;
    notifyListeners();
  }

  void updateDocumentKeyword(String value) {
    if (_documentKeyword == value) {
      return;
    }

    _documentKeyword = value;
    notifyListeners();
  }

  void selectDocumentDateRange({DateTime? startDate, DateTime? endDate}) {
    final normalizedStartDate = _dateOnly(startDate);
    final normalizedEndDate = _dateOnly(endDate);
    if (_isSameDate(_documentStartDate, normalizedStartDate) &&
        _isSameDate(_documentEndDate, normalizedEndDate)) {
      return;
    }

    _documentStartDate = normalizedStartDate;
    _documentEndDate = normalizedEndDate;
    notifyListeners();
  }

  Future<void> searchProducts(String value) async {
    if (!_canMutateDocumentForm) return;
    final requestId = ++_productSearchRequestId;
    _productQuery = value;
    if (_selectedProduct?.productName != value) {
      _selectedProduct = null;
    }
    _formError = null;
    _scheduleDraftSave();

    final repository = inventoryRepository;
    final keyword = value.trim();
    if (repository == null || keyword.isEmpty) {
      _productCandidates = const [];
      _productSearchError = null;
      _isSearchingProducts = false;
      notifyListeners();
      return;
    }

    _isSearchingProducts = true;
    _productSearchError = null;
    notifyListeners();

    final result = await repository.listInventory(keyword: keyword);
    if (_isDisposed) return;
    if (requestId != _productSearchRequestId) {
      return;
    }

    result.when(
      success: (page) {
        _productCandidates = page.items;
        _productSearchError = null;
      },
      failure: (failure) {
        _productCandidates = const [];
        _productSearchError = failure.message;
      },
    );

    _isSearchingProducts = false;
    notifyListeners();
  }

  void selectProduct(InventoryItem product) {
    if (!_canMutateDocumentForm) return;
    _selectedProduct = product;
    _productQuery = product.productName;
    _productCandidates = const [];
    _productSearchError = null;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void addScannedProduct(InventoryItem product) {
    addProductToDraft(product, quantity: isStocktakeAction ? 0 : 1);
  }

  void addProductToDraft(InventoryItem product, {required int quantity}) {
    if (!_canMutateDocumentForm) return;
    if (isConversionAction && _draftLines.isNotEmpty) {
      _formError = '转标准只能选择一个标准商品';
      notifyListeners();
      return;
    }
    if (isStocktakeAction ? quantity < 0 : quantity <= 0) {
      _formError = isStocktakeAction ? '实盘数量不能为负数' : '数量必须大于 0';
      notifyListeners();
      return;
    }
    final index = _draftLines.indexWhere(
      (line) => line.productId == product.productId,
    );
    final lines = List<CreateDocumentLineRequest>.of(_draftLines);
    if (index >= 0) {
      final current = lines[index];
      final nextQuantity = isStocktakeAction
          ? quantity
          : current.quantity + quantity;
      lines[index] = _lineFromProduct(product, nextQuantity);
    } else {
      lines.add(_lineFromProduct(product, quantity));
    }
    _draftLines = List.unmodifiable(lines);
    _selectedProduct = null;
    _productQuery = '';
    _quantityText = '';
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void updateDraftLineQuantity(int productId, int quantity) {
    if (!_canMutateDocumentForm) return;
    if (isStocktakeAction ? quantity < 0 : quantity <= 0) {
      _formError = isStocktakeAction ? '实盘数量不能为负数' : '数量必须大于 0';
      notifyListeners();
      return;
    }
    _draftLines = _draftLines
        .map(
          (line) => line.productId == productId
              ? CreateDocumentLineRequest(
                  productId: line.productId,
                  productName: line.productName,
                  quantity: quantity,
                  actualQuantity: isStocktakeAction ? quantity : null,
                  nonStandardInventoryId: line.nonStandardInventoryId,
                  retailPrice: line.retailPrice,
                )
              : line,
        )
        .toList(growable: false);
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void removeDraftLine(int productId) {
    if (!_canMutateDocumentForm) return;
    _draftLines = _draftLines
        .where((line) => line.productId != productId)
        .toList(growable: false);
    _scheduleDraftSave();
    notifyListeners();
  }

  CreateDocumentLineRequest _lineFromProduct(
    InventoryItem product,
    int quantity,
  ) {
    return CreateDocumentLineRequest(
      productId: product.productId,
      productName: product.productName,
      quantity: quantity,
      actualQuantity: isStocktakeAction ? quantity : null,
      retailPrice: _selectedAction.docType == 2 ? product.retailPrice : null,
    );
  }

  Future<void> loadNonStandardInventory() async {
    final repository = inventoryRepository;
    if (repository == null) {
      _nonStandardInventoryItems = const [];
      _nonStandardInventoryError = null;
      notifyListeners();
      return;
    }

    _isLoadingNonStandardInventory = true;
    _nonStandardInventoryError = null;
    notifyListeners();

    final items = <NonStandardInventoryItem>[];
    var pageNumber = 1;
    while (pageNumber > 0) {
      final result = await repository.listNonStandardInventory(
        page: pageNumber,
      );
      if (_isDisposed) return;
      switch (result) {
        case Success(:final data):
          items.addAll(data.items);
          pageNumber = data.items.isEmpty || !data.hasNextPage
              ? 0
              : data.nextPage;
        case FailureResult(:final failure):
          _nonStandardInventoryItems = const [];
          _nonStandardInventoryError = failure.message;
          pageNumber = 0;
      }
    }
    if (_nonStandardInventoryError == null) {
      _nonStandardInventoryItems = _mergeById(
        const [],
        items,
        (item) => item.id,
      );
      _clearStaleNonStandardInventory();
    }

    _isLoadingNonStandardInventory = false;
    notifyListeners();
  }

  Future<void> loadReturnSourceDocuments() async {
    if (!isReturnAction) {
      return;
    }

    final repository = this.repository;
    if (repository == null) {
      _hasLoadedReturnSourceDocuments = true;
      _returnSourceDocuments = const [];
      _returnSourceError = null;
      _isLoadingReturnSources = false;
      _resolvePendingReturnSourceDocument();
      _clearStaleReturnSourceDocument();
      notifyListeners();
      return;
    }

    final selectedAction = _selectedAction;
    _hasLoadedReturnSourceDocuments = true;
    _isLoadingReturnSources = true;
    _returnSourceError = null;
    notifyListeners();

    final documents = <DocumentRecord>[];
    var pageNumber = 1;
    while (true) {
      final result = await repository.listRecentDocuments(
        docType: 2,
        page: pageNumber,
      );
      if (_isDisposed) return;
      if (_selectedAction != selectedAction || !isReturnAction) return;
      switch (result) {
        case Success(:final data):
          documents.addAll(data.items);
          if (data.items.isEmpty || !data.hasNextPage) {
            _returnSourceDocuments = _eligibleReturnSourceDocuments(documents);
            _returnSourceError = null;
            pageNumber = 0;
          } else {
            pageNumber = data.nextPage;
          }
        case FailureResult(:final failure):
          _returnSourceDocuments = const [];
          _returnSourceError = failure.message;
          pageNumber = 0;
      }
      if (pageNumber == 0) break;
    }
    if (_returnSourceError == null) {
      _resolvePendingReturnSourceDocument();
    }
    _clearStaleReturnSourceDocument();

    _isLoadingReturnSources = false;
    notifyListeners();
  }

  void _clearStaleNonStandardInventory() {
    final selectedInventory = _selectedNonStandardInventory;
    if (selectedInventory == null) {
      return;
    }

    final sourceStillAvailable = _nonStandardInventoryItems.any(
      (item) => item.id == selectedInventory.id,
    );
    if (!sourceStillAvailable) {
      _selectedNonStandardInventory = null;
      _nonStandardSourceId = null;
    }
  }

  List<DocumentRecord> _eligibleReturnSourceDocuments(
    Iterable<DocumentRecord> documents,
  ) {
    return documents
        .where(
          (document) =>
              document.docType == 2 &&
              (document.status == '已完成' || document.status == '已结算'),
        )
        .toList(growable: false);
  }

  void selectNonStandardInventory(NonStandardInventoryItem item) {
    if (!_canMutateDocumentForm) return;
    _selectedNonStandardInventory = item;
    _nonStandardSourceId = item.id;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void selectTargetWarehouse(Warehouse warehouse) {
    if (!_canMutateDocumentForm) return;
    _selectedTargetWarehouse = warehouse;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void selectReturnSourceDocument(DocumentRecord document) {
    if (!_canMutateDocumentForm) return;
    _selectedReturnSourceDocument = document;
    _pendingReturnSourceDocumentId = null;
    _returnSourceError = null;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void updateQuantity(String value) {
    if (!_canMutateDocumentForm) return;
    _quantityText = value;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  void updateRemark(String value) {
    if (!_canMutateDocumentForm) return;
    _remark = value;
    _formError = null;
    _scheduleDraftSave();
    notifyListeners();
  }

  String ensureDraftId() {
    _ensureDraftIdentity();
    return _activeDraftId!;
  }

  void updateAttachmentStagingIds(List<String> requestIds) {
    if (!_canMutateDocumentForm) return;
    _attachmentStagingIds = List.unmodifiable(requestIds);
    _scheduleDraftSave();
    notifyListeners();
  }

  void reconcileAttachmentStagingIds(String draftId, List<String> requestIds) {
    if (_isDisposed || _activeDraftId != draftId) return;
    _attachmentStagingIds = List.unmodifiable(requestIds);
    _scheduleDraftSave();
    notifyListeners();
  }

  void setAttachmentMutationInProgress(bool value) {
    if (_isDisposed || _isAttachmentMutationInProgress == value) return;
    _isAttachmentMutationInProgress = value;
    notifyListeners();
  }

  void confirmDraftReview() {
    if (!_canMutateDocumentForm) return;
    if (!_requiresDraftReview) return;
    _requiresDraftReview = false;
    _draftObservedRoleCode = observedRoleCode;
    _scheduleDraftSave();
    notifyListeners();
  }

  Future<void> saveDraft() async {
    _draftSaveTimer?.cancel();
    if (!_canPersistDraft || _draftSubmissionBarrier) return;
    _ensureDraftIdentity();
    _draftDirty = true;
    await _ensureDraftSaveWorker();
  }

  Future<void> _ensureDraftSaveWorker() async {
    while (_draftDirty && !_isDisposed) {
      final current = _draftSaveInFlight;
      if (current != null) {
        await current;
        continue;
      }
      final generation = _draftContextGeneration;
      final worker = _runDraftSaveWorker(generation);
      _draftSaveInFlight = worker;
      await worker;
      if (identical(_draftSaveInFlight, worker)) {
        _draftSaveInFlight = null;
      }
    }
  }

  Future<void> _runDraftSaveWorker(int generation) async {
    while (_draftDirty &&
        !_isDisposed &&
        generation == _draftContextGeneration) {
      _draftDirty = false;
      await _persistDraft(generation);
    }
  }

  Future<void> _drainDraftSavesForSubmit() async {
    if (!_canPersistDraft) return;
    _ensureDraftIdentity();
    _draftDirty = true;
    while (_draftDirty || _draftSaveInFlight != null) {
      await _ensureDraftSaveWorker();
    }
  }

  Future<bool> openDraft(String draftId) async {
    final openGeneration = ++_draftOpenGeneration;
    final repository = draftRepository;
    final activeAccountId = accountId;
    final warehouseId = currentWarehouse?.id;
    if (repository == null || activeAccountId == null || warehouseId == null) {
      return false;
    }
    final draft = await repository.load(
      accountId: activeAccountId,
      draftId: draftId,
    );
    if (_isDisposed || openGeneration != _draftOpenGeneration) {
      return false;
    }
    if (draft == null) {
      _draftSaveError = '草稿不存在或不属于当前账号';
      notifyListeners();
      return false;
    }
    if (draft.warehouseId != warehouseId) {
      _draftSaveError = '请切换到草稿所属仓库后再打开';
      notifyListeners();
      return false;
    }
    if (!canManageAdminDocumentActions && _isAdminOnlyDocType(draft.docType)) {
      _draftSaveError = '当前账号无权使用该单据类型';
      notifyListeners();
      return false;
    }

    _draftSaveTimer?.cancel();
    _draftContextGeneration += 1;
    _draftDirty = false;
    _activeDraftId = draft.id;
    _draftCreatedAt = draft.createdAt;
    _draftVersion = draft.version;
    _draftSaveError = null;
    _draftObservedRoleCode = draft.observedRoleCode;
    _requiresDraftReview = draft.observedRoleCode != observedRoleCode;
    _attachmentStagingIds = List.unmodifiable(draft.attachmentStagingIds);
    _selectedAction = _actions.firstWhere(
      (action) => action.docType == draft.docType,
      orElse: () => _actions.first,
    );
    _draftLines = _linesFromDraft(draft.payload['lines']);
    _remark = draft.payload['remark']?.toString() ?? '';
    _productQuery = draft.payload['product_query']?.toString() ?? '';
    _quantityText = draft.payload['quantity_text']?.toString() ?? '';
    _selectedProduct = _productFromDraft(draft.payload['pending_product']);
    _nonStandardSourceId = _intValue(draft.payload['non_standard_source_id']);
    _selectedNonStandardInventory = null;
    final targetWarehouseId = _intValue(draft.payload['target_warehouse_id']);
    _selectedTargetWarehouse = targetWarehouseId == null
        ? null
        : _warehouseById(targetWarehouseId);
    final sourceDocumentId = _intValue(draft.payload['source_document_id']);
    _selectedReturnSourceDocument = sourceDocumentId == null
        ? null
        : _documentById(sourceDocumentId);
    _pendingReturnSourceDocumentId = _selectedReturnSourceDocument == null
        ? sourceDocumentId
        : null;
    _returnSourceError = null;
    if (_hasLoadedReturnSourceDocuments) {
      _resolvePendingReturnSourceDocument();
    }
    _formError = null;
    notifyListeners();
    return true;
  }

  bool get _canPersistDraft =>
      draftRepository != null &&
      accountId != null &&
      accountId!.isNotEmpty &&
      currentWarehouse != null;

  void _scheduleDraftSave() {
    if (!_canPersistDraft || _isDisposed || _draftSubmissionBarrier) return;
    _ensureDraftIdentity();
    _draftDirty = true;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(autosaveDelay, () => unawaited(saveDraft()));
  }

  void _ensureDraftIdentity() {
    if (_activeDraftId != null) return;
    _activeDraftId = draftIdFactory();
    _draftCreatedAt = now().toUtc();
    _draftVersion = 0;
    _draftObservedRoleCode = observedRoleCode;
  }

  Future<void> _persistDraft(int generation) async {
    final repository = draftRepository!;
    final timestamp = now().toUtc();
    final draftId = _activeDraftId!;
    final activeAccountId = accountId!;
    final warehouseId = currentWarehouse!.id;
    final expectedVersion = _draftVersion;
    final request = CreateDocumentRequest(
      docType: _selectedAction.docType,
      typeLabel: _selectedAction.label,
      lines: _draftLines,
      toWarehouseId: _selectedTargetWarehouse?.id,
      refDocId:
          _selectedReturnSourceDocument?.id ?? _pendingReturnSourceDocumentId,
      remark: _remark,
    );
    final payload = Map<String, Object?>.from(request.toDraftPayload())
      ..['product_query'] = _productQuery
      ..['quantity_text'] = _quantityText;
    if (_nonStandardSourceId case final sourceId?) {
      payload['non_standard_source_id'] = sourceId;
    }
    if (_selectedProduct case final product?) {
      payload['pending_product'] = {
        'product_id': product.productId,
        'product_name': product.productName,
        'sku': product.sku,
        'status_label': product.statusLabel,
        'image_url': product.imageUrl,
        'retail_price': product.retailPrice,
      };
    }
    final draft = DocumentDraft(
      id: draftId,
      accountId: activeAccountId,
      warehouseId: warehouseId,
      docType: _selectedAction.docType,
      observedRoleCode: _draftObservedRoleCode ?? observedRoleCode,
      payload: payload,
      attachmentStagingIds: _attachmentStagingIds,
      createdAt: _draftCreatedAt ?? timestamp,
      updatedAt: timestamp,
      version: expectedVersion,
    );
    final result = await repository.save(
      draft,
      expectedVersion: expectedVersion,
    );
    if (_isDisposed ||
        generation != _draftContextGeneration ||
        _activeDraftId != draftId ||
        accountId != activeAccountId ||
        currentWarehouse?.id != warehouseId) {
      return;
    }
    result.when(
      success: (saved) {
        _draftVersion = saved.version;
        _draftCreatedAt = saved.createdAt;
        _draftSaveError = null;
      },
      failure: (failure) => _draftSaveError = failure.message,
    );
    notifyListeners();
  }

  List<CreateDocumentLineRequest> _linesFromDraft(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((line) {
          return CreateDocumentLineRequest(
            productId: _intValue(line['product_id']) ?? 0,
            productName: line['product_name']?.toString() ?? '',
            quantity: _intValue(line['quantity']) ?? 0,
            actualQuantity: _intValue(line['actual_quantity']),
            nonStandardInventoryId: _intValue(
              line['non_standard_inventory_id'],
            ),
            retailPrice: _doubleValue(line['retail_price']),
          );
        })
        .toList(growable: false);
  }

  InventoryItem? _productFromDraft(Object? value) {
    if (value is! Map) return null;
    final productId = _intValue(value['product_id']);
    if (productId == null) return null;
    return InventoryItem(
      id: productId,
      productId: productId,
      productName: value['product_name']?.toString() ?? '',
      sku: value['sku']?.toString() ?? '',
      availableQuantity: 0,
      stockQuantity: 0,
      statusLabel: value['status_label']?.toString() ?? '',
      imageUrl: value['image_url']?.toString() ?? '',
      retailPrice: _doubleValue(value['retail_price']) ?? 0,
    );
  }

  int? _intValue(Object? value) => value is num ? value.toInt() : null;
  double? _doubleValue(Object? value) => value is num ? value.toDouble() : null;

  Warehouse? _warehouseById(int id) {
    for (final warehouse in warehouses) {
      if (warehouse.id == id) return warehouse;
    }
    return null;
  }

  DocumentRecord? _documentById(int id) {
    for (final document in [..._returnSourceDocuments, ..._recentDocuments]) {
      if (document.id == id) return document;
    }
    return null;
  }

  Future<void> load() async {
    final repository = this.repository;
    if (repository == null) {
      _recentDocuments = const [];
      _transactions = const [];
      _errorMessage = null;
      _transactionError = null;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _transactionError = null;
    notifyListeners();

    await _loadDocumentsFirstPage();
    if (_isDisposed) return;
    await _loadTransactionsFirstPage();
    if (_isDisposed) return;

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadDocumentsFirstPage() async {
    final repository = this.repository;
    if (repository == null) return;
    final generation = ++_documentGeneration;
    final docType = _selectedDocumentTypeFilter;
    _documentPage = 0;
    _documentTotal = 0;
    _isLoadingMoreDocuments = false;
    _documentsReachedEnd = false;
    _documentLoadMoreFailure = null;
    final result = await repository.listRecentDocuments(docType: docType);
    if (_isDisposed) return;
    if (generation != _documentGeneration ||
        docType != _selectedDocumentTypeFilter) {
      return;
    }
    result.when(
      success: (page) {
        _recentDocuments = _mergeById(const [], page.items, (item) => item.id);
        _documentPage = page.page;
        _documentTotal = page.total;
        _documentsReachedEnd = page.items.isEmpty || !page.hasNextPage;
        _clearStaleReturnSourceDocument();
        _errorMessage = null;
        _captureReadStatus(repository);
      },
      failure: (failure) => _errorMessage = failure.message,
    );
    notifyListeners();
  }

  Future<void> _loadTransactionsFirstPage() async {
    final repository = this.repository;
    if (repository == null) return;
    final generation = ++_transactionGeneration;
    _transactionPage = 0;
    _transactionTotal = 0;
    _isLoadingMoreTransactions = false;
    _transactionsReachedEnd = false;
    _transactionLoadMoreFailure = null;
    final result = await repository.listTransactions();
    if (_isDisposed) return;
    if (generation != _transactionGeneration) return;
    result.when(
      success: (page) {
        _transactions = _mergeById(const [], page.items, (item) => item.id);
        _transactionPage = page.page;
        _transactionTotal = page.total;
        _transactionsReachedEnd = page.items.isEmpty || !page.hasNextPage;
        _transactionError = null;
      },
      failure: (failure) => _transactionError = failure.message,
    );
    notifyListeners();
  }

  Future<void> loadMoreDocuments() async {
    final repository = this.repository;
    if (repository == null || _isLoadingMoreDocuments || !hasMoreDocuments) {
      return;
    }
    final generation = _documentGeneration;
    final docType = _selectedDocumentTypeFilter;
    _isLoadingMoreDocuments = true;
    _documentLoadMoreFailure = null;
    notifyListeners();
    final result = await repository.listRecentDocuments(
      docType: docType,
      page: _documentPage + 1,
    );
    if (_isDisposed) return;
    if (generation != _documentGeneration ||
        docType != _selectedDocumentTypeFilter) {
      return;
    }
    result.when(
      success: (page) {
        _recentDocuments = _mergeById(
          _recentDocuments,
          page.items,
          (item) => item.id,
        );
        _documentPage = page.page;
        _documentTotal = page.total;
        _documentsReachedEnd = page.items.isEmpty || !page.hasNextPage;
        _captureReadStatus(repository);
      },
      failure: (failure) => _documentLoadMoreFailure = failure,
    );
    _isLoadingMoreDocuments = false;
    notifyListeners();
  }

  Future<void> retryLoadMoreDocuments() => loadMoreDocuments();

  void _captureReadStatus(DocumentsRepository repository) {
    _readStatus = repository is DocumentReadMetadata
        ? (repository as DocumentReadMetadata).lastReadStatus
        : null;
  }

  String _formatCacheTime(DateTime dateTime) {
    final value = dateTime.toLocal();
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
  }

  Future<void> loadMoreTransactions() async {
    final repository = this.repository;
    if (repository == null ||
        _isLoadingMoreTransactions ||
        !hasMoreTransactions) {
      return;
    }
    final generation = _transactionGeneration;
    _isLoadingMoreTransactions = true;
    _transactionLoadMoreFailure = null;
    notifyListeners();
    final result = await repository.listTransactions(
      page: _transactionPage + 1,
    );
    if (_isDisposed) return;
    if (generation != _transactionGeneration) return;
    result.when(
      success: (page) {
        _transactions = _mergeById(
          _transactions,
          page.items,
          (item) => item.id,
        );
        _transactionPage = page.page;
        _transactionTotal = page.total;
        _transactionsReachedEnd = page.items.isEmpty || !page.hasNextPage;
      },
      failure: (failure) => _transactionLoadMoreFailure = failure,
    );
    _isLoadingMoreTransactions = false;
    notifyListeners();
  }

  Future<void> retryLoadMoreTransactions() => loadMoreTransactions();

  List<T> _mergeById<T>(
    List<T> existing,
    List<T> incoming,
    int Function(T item) idOf,
  ) {
    final merged = List<T>.of(existing);
    final indexes = <int, int>{
      for (var index = 0; index < merged.length; index += 1)
        idOf(merged[index]): index,
    };
    for (final item in incoming) {
      final id = idOf(item);
      final index = indexes[id];
      if (index == null) {
        indexes[id] = merged.length;
        merged.add(item);
      } else {
        merged[index] = item;
      }
    }
    return List<T>.unmodifiable(merged);
  }

  void _clearStaleReturnSourceDocument() {
    final selectedSource = _selectedReturnSourceDocument;
    if (selectedSource == null) {
      return;
    }

    final sourceStillAvailable = returnSourceDocuments.any(
      (document) => document.id == selectedSource.id,
    );
    if (!sourceStillAvailable) {
      _selectedReturnSourceDocument = null;
    }
  }

  void _resolvePendingReturnSourceDocument() {
    final sourceDocumentId = _pendingReturnSourceDocumentId;
    if (sourceDocumentId == null || !_hasLoadedReturnSourceDocuments) {
      return;
    }

    for (final document in _returnSourceDocuments) {
      if (document.id == sourceDocumentId) {
        _selectedReturnSourceDocument = document;
        _pendingReturnSourceDocumentId = null;
        _returnSourceError = null;
        return;
      }
    }

    _selectedReturnSourceDocument = null;
    _pendingReturnSourceDocumentId = null;
    _returnSourceError = '原销售单已失效，请重新选择';
  }

  Future<bool> createDocument() async {
    if (_isSubmitting) {
      return false;
    }
    if (_isAttachmentMutationInProgress) {
      _formError = '附件操作进行中，请稍后提交';
      notifyListeners();
      return false;
    }
    if (!canManageAdminDocumentActions &&
        _isAdminOnlyDocType(_selectedAction.docType)) {
      _formError = '当前账号无权使用该单据类型';
      notifyListeners();
      return false;
    }
    if (_requiresDraftReview) {
      _formError = '请确认草稿复核后再提交';
      notifyListeners();
      return false;
    }

    final selectedProduct = _selectedProduct;
    final quantity = int.tryParse(_quantityText.trim());
    var submissionLines = List<CreateDocumentLineRequest>.of(_draftLines);
    if (selectedProduct != null && quantity != null) {
      final invalidQuantity = isStocktakeAction ? quantity < 0 : quantity <= 0;
      if (invalidQuantity) {
        _formError = isStocktakeAction ? '实盘数量不能为负数' : '数量必须大于 0';
        notifyListeners();
        return false;
      }
      final manualLine = _lineFromProduct(selectedProduct, quantity);
      final index = submissionLines.indexWhere(
        (line) => line.productId == manualLine.productId,
      );
      if (index >= 0) {
        final current = submissionLines[index];
        submissionLines[index] = isStocktakeAction
            ? manualLine
            : CreateDocumentLineRequest(
                productId: current.productId,
                productName: current.productName,
                quantity: current.quantity + quantity,
                retailPrice: current.retailPrice,
              );
      } else {
        submissionLines.add(manualLine);
      }
    }
    if (submissionLines.isEmpty) {
      _formError = isStocktakeAction ? '请选择商品并输入实盘数量' : '请选择商品并输入数量';
      notifyListeners();
      return false;
    }

    final targetWarehouse = _selectedTargetWarehouse;
    if (isTransferAction && targetWarehouse == null) {
      _formError = '请选择调拨目标仓库';
      notifyListeners();
      return false;
    }

    final returnSourceDocument = _selectedReturnSourceDocument;
    if (isReturnAction && returnSourceDocument == null) {
      _formError = '请选择原销售单';
      notifyListeners();
      return false;
    }
    if (isReturnAction && returnSourceDocument != null) {
      final wrongProduct = submissionLines.any(
        (line) => line.productName != returnSourceDocument.productName,
      );
      final totalQuantity = submissionLines.fold<int>(
        0,
        (total, line) => total + line.quantity,
      );
      if (wrongProduct || totalQuantity > returnSourceDocument.quantity) {
        _formError = '退货商品必须来自原销售单且数量不能超过原单';
        notifyListeners();
        return false;
      }
    }

    if (isConversionAction && _nonStandardSourceId == null) {
      _formError = '请选择非标库存';
      notifyListeners();
      return false;
    }
    if (isConversionAction && submissionLines.length != 1) {
      _formError = '转标准需要一个非标来源和一个标准商品';
      notifyListeners();
      return false;
    }
    final repository = this.repository;
    if (repository == null) {
      _formError = '单据服务未配置';
      notifyListeners();
      return false;
    }

    _draftSubmissionBarrier = true;
    _submissionEpoch += 1;
    _productSearchRequestId += 1;
    _isSearchingProducts = false;
    _productCandidates = const [];
    _draftSaveTimer?.cancel();
    _isSubmitting = true;
    final hadLoadedDocumentPage = _documentPage > 0;
    _formError = null;
    notifyListeners();

    if (isConversionAction) {
      final source = await _revalidateNonStandardSource();
      if (_isDisposed) return false;
      if (source == null) {
        _formError = _nonStandardInventoryError ?? '非标库存已不可用，请重新选择';
        _releaseSubmissionBarrier();
        return false;
      }
      final line = submissionLines.single;
      submissionLines = [
        CreateDocumentLineRequest(
          productId: line.productId,
          productName: line.productName,
          quantity: line.quantity,
          nonStandardInventoryId: source.id,
        ),
      ];
    }

    await _drainDraftSavesForSubmit();
    if (_isDisposed) return false;

    final submittedDraftId = _activeDraftId ?? ensureDraftId();
    final submittedAccountId = accountId;
    final request = CreateDocumentRequest(
      docType: _selectedAction.docType,
      typeLabel: _selectedAction.label,
      requestId: _draftRequestId ??= const Uuid().v4(),
      lines: List.unmodifiable(submissionLines),
      toWarehouseId: isTransferAction ? targetWarehouse?.id : null,
      refDocId: isReturnAction ? returnSourceDocument?.id : null,
      remark: _remark,
    );
    final result = await repository.createDocument(request);
    if (_isDisposed) return false;

    var created = false;
    if (result case Success<DocumentRecord>(:final data)) {
      final document = data;
      _recentDocuments = [
        _withSubmittedLineSummary(
          document: document,
          line: submissionLines.first,
        ),
        ..._recentDocuments,
      ];
      _selectedProduct = null;
      _productQuery = '';
      _productCandidates = const [];
      _selectedNonStandardInventory = null;
      _nonStandardSourceId = null;
      _selectedTargetWarehouse = null;
      _selectedReturnSourceDocument = null;
      _draftLines = const [];
      _draftRequestId = null;
      _quantityText = '';
      _remark = '';
      _attachmentStagingIds = const [];
      _requiresDraftReview = false;
      _draftObservedRoleCode = null;
      _formError = null;
      created = true;
      notifyListeners();
    } else if (result case FailureResult<DocumentRecord>(:final failure)) {
      if (_canOfferOfflineQueue(failure) &&
          submittedAccountId != null &&
          currentWarehouse != null &&
          outboxRepository != null &&
          submissionStagingStore != null) {
        _pendingLifecycleSubmission = null;
        _pendingOfflineSubmission = _PendingOfflineSubmission(
          request: request,
          accountId: submittedAccountId,
          warehouseId: currentWarehouse!.id,
          localAggregateId: submittedDraftId,
          attachmentRequestIds: List.unmodifiable(_attachmentStagingIds),
          requiresStatusProbe: failure is TransportUnknownFailure,
          review: OfflineSubmissionReview(
            warehouseName: currentWarehouse!.name,
            documentType: request.typeLabel,
            lineCount: request.effectiveLines.length,
            lines: request.effectiveLines
                .map((line) => '${line.productName} × ${line.quantity}')
                .toList(growable: false),
            staleAssumptions: const ['库存、原单状态和权限将在同步前重新校验', '附件内容必须与当前暂存快照一致'],
          ),
        );
        _formError = '网络结果不确定，确认后可保存到待同步';
      } else {
        _pendingOfflineSubmission = null;
        _formError = failure.message;
      }
    }

    if (created && submittedAccountId != null && draftRepository != null) {
      try {
        await draftRepository!.delete(
          accountId: submittedAccountId,
          draftId: submittedDraftId,
        );
        _activeDraftId = null;
        _draftCreatedAt = null;
        _draftVersion = 0;
        _draftSaveError = null;
      } on Object {
        _draftSaveError = '单据已提交，但本地草稿清理失败';
      }
      if (_isDisposed) return false;
    }

    if (created && hadLoadedDocumentPage) {
      await _loadDocumentsFirstPage();
      if (_isDisposed) return false;
    }

    _draftSubmissionBarrier = false;
    _isSubmitting = false;
    notifyListeners();
    return created;
  }

  Future<bool> confirmOfflineSubmission() async {
    if (_offlineEnqueueInFlight) return false;
    final create = _pendingOfflineSubmission;
    final lifecycle = _pendingLifecycleSubmission;
    final outbox = outboxRepository;
    if (outbox == null || (create == null && lifecycle == null)) return false;

    _offlineEnqueueInFlight = true;
    _formError = null;
    _documentActionError = null;
    notifyListeners();
    try {
      if (create != null) return await _enqueueCreateSubmission(create, outbox);
      return await _enqueueLifecycleSubmission(lifecycle!, outbox);
    } finally {
      _offlineEnqueueInFlight = false;
      notifyListeners();
    }
  }

  Future<bool> _enqueueCreateSubmission(
    _PendingOfflineSubmission pending,
    OutboxRepository outbox,
  ) async {
    final staging = submissionStagingStore!;
    final staged = <StagedAttachment>[];
    for (final requestId in pending.attachmentRequestIds) {
      final result = await staging.loadStaged(
        userId: pending.accountId,
        requestId: requestId,
      );
      if (result case FailureResult<StagedAttachment>(:final failure)) {
        _formError = failure.message;
        return false;
      }
      final attachment = (result as Success<StagedAttachment>).data;
      if (attachment.pending.binding.businessType != 'document_draft' ||
          attachment.pending.binding.localDraftId != pending.localAggregateId ||
          attachment.sha256.isEmpty) {
        _formError = '附件暂存归属或内容快照已变化，请重新复核';
        return false;
      }
      staged.add(attachment);
    }

    final createdAt = now().toUtc();
    final createOperationId = 'document-create-${pending.request.requestId}';
    final cleanup = {
      'draftId': pending.localAggregateId,
      'attachmentRequestIds': List<Object?>.from(pending.attachmentRequestIds),
    };
    final createOperation = OutboxOperation(
      operationId: createOperationId,
      idempotencyKey: pending.request.requestId,
      accountId: pending.accountId,
      warehouseId: pending.warehouseId,
      kind: OutboxOperationKind.documentCreate,
      payload: {
        'version': 1,
        'localAggregateId': pending.localAggregateId,
        'attachmentRequestIds': List<Object?>.from(
          pending.attachmentRequestIds,
        ),
        'request': _outboxDocumentRequest(pending.request),
        if (staged.isEmpty) 'cleanup': cleanup,
      },
      state: OutboxState.queued,
      createdAt: createdAt,
      requiresStatusProbe: pending.requiresStatusProbe,
    );
    final operations = <OutboxOperation>[createOperation];
    final dependencies = <String, Set<String>>{};
    var dependencyId = createOperationId;
    for (var index = 0; index < staged.length; index += 1) {
      final attachment = staged[index];
      final terminal = index == staged.length - 1;
      final operation = OutboxOperation(
        operationId: 'attachment-upload-${attachment.pending.requestId}',
        idempotencyKey: attachment.pending.requestId,
        accountId: pending.accountId,
        warehouseId: pending.warehouseId,
        kind: OutboxOperationKind.attachmentUpload,
        payload: {
          'version': 1,
          'requestId': attachment.pending.requestId,
          'expectedSize': attachment.pending.fileSize,
          'expectedSha256': attachment.sha256,
          'localAggregateId': pending.localAggregateId,
          if (terminal) 'cleanup': cleanup,
        },
        state: OutboxState.queued,
        createdAt: createdAt.add(Duration(microseconds: index + 1)),
        requiresStatusProbe: pending.requiresStatusProbe,
      );
      operations.add(operation);
      dependencies[operation.operationId] = {dependencyId};
      dependencyId = operation.operationId;
    }

    final result = await outbox.enqueueGraph(
      OutboxGraph(operations: operations, dependencies: dependencies),
    );
    if (result case FailureResult<List<OutboxOperation>>(:final failure)) {
      _formError = failure.message;
      return false;
    }

    _pendingOfflineSubmission = null;
    _formError = '已保存到待同步，请前往同步中心复核';
    return true;
  }

  Future<bool> _enqueueLifecycleSubmission(
    _PendingLifecycleSubmission pending,
    OutboxRepository outbox,
  ) async {
    final createdAt = now().toUtc();
    final referenceOperation = OutboxOperation(
      operationId: 'document-reference-${pending.requestId}',
      idempotencyKey: 'document-reference:${pending.requestId}',
      accountId: pending.accountId,
      warehouseId: pending.warehouseId,
      kind: OutboxOperationKind.documentReference,
      payload: {'version': 1, 'documentId': pending.documentId},
      state: OutboxState.queued,
      createdAt: createdAt,
    );
    final operation = OutboxOperation(
      operationId: '${pending.kind.wireValue}-${pending.requestId}',
      idempotencyKey: pending.requestId,
      accountId: pending.accountId,
      warehouseId: pending.warehouseId,
      kind: pending.kind,
      payload: const {'version': 1},
      state: OutboxState.queued,
      createdAt: createdAt.add(const Duration(microseconds: 1)),
      requiresStatusProbe: pending.requiresStatusProbe,
    );
    final result = await outbox.enqueueGraph(
      OutboxGraph(
        operations: [referenceOperation, operation],
        dependencies: {
          operation.operationId: {referenceOperation.operationId},
        },
      ),
    );
    if (result case FailureResult<List<OutboxOperation>>(:final failure)) {
      _documentActionError = failure.message;
      return false;
    }
    _pendingLifecycleSubmission = null;
    _documentActionError = '已保存到待同步，请前往同步中心复核';
    return true;
  }

  Map<String, Object?> _outboxDocumentRequest(
    CreateDocumentRequest request,
  ) => {
    'docType': request.docType,
    'typeLabel': request.typeLabel,
    'requestId': request.requestId,
    'lines': request.effectiveLines
        .map(
          (line) => <String, Object?>{
            'productId': line.productId,
            'productName': line.productName,
            'quantity': line.quantity,
            if (line.actualQuantity != null)
              'actualQuantity': line.actualQuantity,
            if (line.nonStandardInventoryId != null)
              'nonStandardInventoryId': line.nonStandardInventoryId,
            if (line.retailPrice != null) 'retailPrice': line.retailPrice,
          },
        )
        .toList(growable: false),
    if (request.toWarehouseId != null) 'toWarehouseId': request.toWarehouseId,
    if (request.refDocId != null) 'refDocId': request.refDocId,
    'remark': request.remark,
  };

  bool _canOfferOfflineQueue(Failure failure) =>
      failure is NetworkFailure || failure is TransportUnknownFailure;

  Future<NonStandardInventoryItem?> _revalidateNonStandardSource() async {
    final sourceId = _nonStandardSourceId;
    if (sourceId == null) return null;
    await loadNonStandardInventory();
    if (_isDisposed) return null;
    for (final item in _nonStandardInventoryItems) {
      if (item.id == sourceId) {
        _selectedNonStandardInventory = item;
        return item;
      }
    }
    return null;
  }

  void _releaseSubmissionBarrier() {
    _draftSubmissionBarrier = false;
    _isSubmitting = false;
    notifyListeners();
  }

  bool get _canMutateDocumentForm =>
      !_draftSubmissionBarrier && !_isSubmitting && !_isDisposed;

  DocumentRecord _withSubmittedLineSummary({
    required DocumentRecord document,
    required CreateDocumentLineRequest line,
  }) {
    if (document.productName.isNotEmpty && document.quantity != 0) {
      return document;
    }

    return DocumentRecord(
      id: document.id,
      docType: document.docType,
      title: document.title,
      number: document.number,
      status: document.status,
      productName: document.productName.isEmpty
          ? line.productName
          : document.productName,
      quantity: document.quantity == 0 ? line.quantity : document.quantity,
      remark: document.remark,
      createdAt: document.createdAt,
    );
  }

  bool canCompleteDocument(DocumentRecord document) {
    if (_isAdminOnlyDocument(document) && !canManageAdminDocumentActions) {
      return false;
    }

    return document.status == '待提交' || document.status == '草稿';
  }

  bool canConfirmStocktakeDocument(DocumentRecord document) {
    return document.docType == 5 && document.status == '盘点中';
  }

  bool canSettleStocktakeDocument(DocumentRecord document) {
    return document.docType == 5 && document.status == '差异已确认';
  }

  bool isCompletingDocument(DocumentRecord document) {
    return _completingDocumentIds.contains(document.id);
  }

  Future<bool> completeDocument(DocumentRecord document) async {
    if (_isAdminOnlyDocument(document) && !canManageAdminDocumentActions) {
      _documentActionError = '无权限操作该单据';
      notifyListeners();
      return false;
    }

    if (!canCompleteDocument(document)) {
      _documentActionError = '当前状态不能完成';
      notifyListeners();
      return false;
    }

    return _runLifecycleAction(
      document: document,
      kind: OutboxOperationKind.documentComplete,
      invalidServiceMessage: '单据服务未配置',
      run: (repository, requestId) =>
          repository.completeDocument(document.id, requestId: requestId),
    );
  }

  Future<bool> confirmStocktakeDocument(DocumentRecord document) async {
    if (!canConfirmStocktakeDocument(document)) {
      _documentActionError = '当前状态不能确认盘点';
      notifyListeners();
      return false;
    }

    return _runLifecycleAction(
      document: document,
      kind: OutboxOperationKind.stocktakeConfirm,
      invalidServiceMessage: '单据服务未配置',
      run: (repository, requestId) =>
          repository.confirmDocument(document.id, requestId: requestId),
    );
  }

  Future<bool> settleStocktakeDocument(DocumentRecord document) async {
    if (!canSettleStocktakeDocument(document)) {
      _documentActionError = '当前状态不能结转盘点';
      notifyListeners();
      return false;
    }

    return _runLifecycleAction(
      document: document,
      kind: OutboxOperationKind.stocktakeSettle,
      invalidServiceMessage: '单据服务未配置',
      run: (repository, requestId) =>
          repository.settleDocument(document.id, requestId: requestId),
    );
  }

  Future<bool> _runLifecycleAction({
    required DocumentRecord document,
    required OutboxOperationKind kind,
    required String invalidServiceMessage,
    required Future<Result<void>> Function(
      DocumentsRepository repository,
      String requestId,
    )
    run,
  }) async {
    if (_completingDocumentIds.contains(document.id)) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _documentActionError = invalidServiceMessage;
      notifyListeners();
      return false;
    }

    _completingDocumentIds = {..._completingDocumentIds, document.id};
    _documentActionError = null;
    notifyListeners();

    final requestKey = '${kind.wireValue}:${document.id}';
    final requestId = _lifecycleRequestIds.putIfAbsent(
      requestKey,
      const Uuid().v4,
    );
    final result = await run(repository, requestId);
    if (_isDisposed) return false;
    var completed = false;
    await result.when(
      success: (_) async {
        completed = true;
        _lifecycleRequestIds.remove(requestKey);
        _documentActionError = null;
        await load();
      },
      failure: (failure) async {
        final currentAccountId = accountId;
        final warehouse = currentWarehouse;
        if (_canOfferOfflineQueue(failure) &&
            currentAccountId != null &&
            warehouse != null &&
            outboxRepository != null) {
          _pendingOfflineSubmission = null;
          _pendingLifecycleSubmission = _PendingLifecycleSubmission(
            kind: kind,
            requestId: requestId,
            documentId: document.id,
            accountId: currentAccountId,
            warehouseId: warehouse.id,
            requiresStatusProbe: failure is TransportUnknownFailure,
            review: OfflineSubmissionReview(
              warehouseName: warehouse.name,
              documentType: document.title,
              lineCount: 0,
              lines: [document.number],
              staleAssumptions: const ['单据状态、库存和权限将在同步前重新校验'],
            ),
          );
          _documentActionError = '网络结果不确定，确认后可保存到待同步';
        } else {
          _pendingLifecycleSubmission = null;
          _documentActionError = failure.message;
        }
      },
    );
    if (_isDisposed) return false;

    _completingDocumentIds = {
      for (final id in _completingDocumentIds)
        if (id != document.id) id,
    };
    notifyListeners();
    return completed;
  }

  bool _matchesDocumentDate(DocumentRecord document) {
    if (_documentStartDate == null && _documentEndDate == null) {
      return true;
    }

    final createdAt = DateTime.tryParse(document.createdAt);
    if (createdAt == null) {
      return false;
    }

    final documentDate = _dateOnly(createdAt)!;
    final startDate = _documentStartDate;
    final endDate = _documentEndDate;
    if (startDate != null && documentDate.isBefore(startDate)) {
      return false;
    }
    if (endDate != null && documentDate.isAfter(endDate)) {
      return false;
    }

    return true;
  }

  DateTime? _dateOnly(DateTime? value) {
    if (value == null) {
      return null;
    }

    return DateTime(value.year, value.month, value.day);
  }

  bool _isSameDate(DateTime? left, DateTime? right) {
    return left?.year == right?.year &&
        left?.month == right?.month &&
        left?.day == right?.day;
  }

  bool _isAdminOnlyAction(DocumentAction action) {
    return _isAdminOnlyDocType(action.docType);
  }

  bool _isAdminOnlyDocument(DocumentRecord document) {
    return _isAdminOnlyDocType(document.docType);
  }

  bool _isAdminOnlyDocType(int docType) {
    return docType == 4 || docType == 6;
  }
}
