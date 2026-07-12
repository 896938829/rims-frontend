import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/result/result.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/resources/app_icons.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/entities/non_standard_inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';

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

final class DocumentsViewModel extends ChangeNotifier {
  DocumentsViewModel({
    this.repository,
    this.inventoryRepository,
    this.currentWarehouse,
    this.warehouses = const [],
    this.canManageAdminDocumentActions = true,
  }) : _selectedAction = _actions.first,
       _recentDocuments = const [],
       _transactions = const [];

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

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  List<DocumentAction> get actions => _actions
      .where(
        (action) =>
            canManageAdminDocumentActions || !_isAdminOnlyAction(action),
      )
      .toList(growable: false);
  List<String> get flowSteps => const ['创建', '确认', '提交', '完成'];
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
  bool get isLoading => _isLoading;
  bool get isSearchingProducts => _isSearchingProducts;
  bool get isLoadingNonStandardInventory => _isLoadingNonStandardInventory;
  bool get isLoadingReturnSources => _isLoadingReturnSources;
  bool get isSubmitting => _isSubmitting;
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
  String get quantityInputLabel => isStocktakeAction ? '实盘数量' : '数量';
  String get quantityInputHint => isStocktakeAction ? '输入实盘数量' : '输入数量';

  void selectAction(DocumentAction action) {
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
      _returnSourceDocuments = const [];
      _returnSourceError = null;
      _hasLoadedReturnSourceDocuments = false;
      _isLoadingReturnSources = false;
    }
    if (!isConversionAction) {
      _selectedNonStandardInventory = null;
    }
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
    _productQuery = value;
    if (_selectedProduct?.productName != value) {
      _selectedProduct = null;
    }
    _formError = null;
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
    final requestId = ++_productSearchRequestId;
    _productQuery = value;
    if (_selectedProduct?.productName != value) {
      _selectedProduct = null;
    }
    _formError = null;

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
    _selectedProduct = product;
    _productQuery = product.productName;
    _productCandidates = const [];
    _productSearchError = null;
    _formError = null;
    notifyListeners();
  }

  void addScannedProduct(InventoryItem product) {
    addProductToDraft(product, quantity: isStocktakeAction ? 0 : 1);
  }

  void addProductToDraft(InventoryItem product, {required int quantity}) {
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
    notifyListeners();
  }

  void updateDraftLineQuantity(int productId, int quantity) {
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
    notifyListeners();
  }

  void removeDraftLine(int productId) {
    _draftLines = _draftLines
        .where((line) => line.productId != productId)
        .toList(growable: false);
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
    _selectedNonStandardInventory = item;
    _formError = null;
    notifyListeners();
  }

  void selectTargetWarehouse(Warehouse warehouse) {
    _selectedTargetWarehouse = warehouse;
    _formError = null;
    notifyListeners();
  }

  void selectReturnSourceDocument(DocumentRecord document) {
    _selectedReturnSourceDocument = document;
    _formError = null;
    notifyListeners();
  }

  void updateQuantity(String value) {
    _quantityText = value;
    _formError = null;
    notifyListeners();
  }

  void updateRemark(String value) {
    _remark = value;
    _formError = null;
    notifyListeners();
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
      },
      failure: (failure) => _documentLoadMoreFailure = failure,
    );
    _isLoadingMoreDocuments = false;
    notifyListeners();
  }

  Future<void> retryLoadMoreDocuments() => loadMoreDocuments();

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

  Future<bool> createDocument() async {
    if (_isSubmitting) {
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

    final nonStandardInventory = _selectedNonStandardInventory;
    if (isConversionAction && nonStandardInventory == null) {
      _formError = '请选择非标库存';
      notifyListeners();
      return false;
    }
    if (isConversionAction && submissionLines.length != 1) {
      _formError = '转标准需要一个非标来源和一个标准商品';
      notifyListeners();
      return false;
    }
    if (isConversionAction) {
      final line = submissionLines.single;
      submissionLines = [
        CreateDocumentLineRequest(
          productId: line.productId,
          productName: line.productName,
          quantity: line.quantity,
          nonStandardInventoryId: nonStandardInventory?.id,
        ),
      ];
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '单据服务未配置';
      notifyListeners();
      return false;
    }

    _isSubmitting = true;
    final hadLoadedDocumentPage = _documentPage > 0;
    _formError = null;
    notifyListeners();

    final result = await repository.createDocument(
      CreateDocumentRequest(
        docType: _selectedAction.docType,
        typeLabel: _selectedAction.label,
        requestId: _draftRequestId ??= const Uuid().v4(),
        lines: submissionLines,
        toWarehouseId: isTransferAction ? targetWarehouse?.id : null,
        refDocId: isReturnAction ? returnSourceDocument?.id : null,
        remark: _remark,
      ),
    );
    if (_isDisposed) return false;

    var created = false;
    result.when(
      success: (document) {
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
        _selectedTargetWarehouse = null;
        _selectedReturnSourceDocument = null;
        _draftLines = const [];
        _draftRequestId = null;
        _quantityText = '';
        _remark = '';
        _formError = null;
        created = true;
        notifyListeners();
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );

    if (created && hadLoadedDocumentPage) {
      await _loadDocumentsFirstPage();
      if (_isDisposed) return false;
    }

    _isSubmitting = false;
    notifyListeners();
    return created;
  }

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
      invalidServiceMessage: '单据服务未配置',
      run: (repository) => repository.completeDocument(document.id),
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
      invalidServiceMessage: '单据服务未配置',
      run: (repository) => repository.confirmDocument(document.id),
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
      invalidServiceMessage: '单据服务未配置',
      run: (repository) => repository.settleDocument(document.id),
    );
  }

  Future<bool> _runLifecycleAction({
    required DocumentRecord document,
    required String invalidServiceMessage,
    required Future<Result<void>> Function(DocumentsRepository repository) run,
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

    final result = await run(repository);
    if (_isDisposed) return false;
    var completed = false;
    await result.when(
      success: (_) async {
        completed = true;
        _documentActionError = null;
        await load();
      },
      failure: (failure) async {
        _documentActionError = failure.message;
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
