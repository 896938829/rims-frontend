import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
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
  Set<int> _completingDocumentIds = const {};
  DocumentAction _selectedAction;
  InventoryItem? _selectedProduct;
  NonStandardInventoryItem? _selectedNonStandardInventory;
  Warehouse? _selectedTargetWarehouse;
  DocumentRecord? _selectedReturnSourceDocument;
  String _productQuery = '';
  String _documentKeyword = '';
  String _quantityText = '';
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
  String get quantityInputLabel => isStocktakeAction ? '实盘数量' : '数量';
  String get quantityInputHint => isStocktakeAction ? '输入实盘数量' : '输入数量';

  void selectAction(DocumentAction action) {
    if (_isAdminOnlyAction(action) && !canManageAdminDocumentActions) {
      return;
    }

    _selectedAction = action;
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
    unawaited(load());
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
    if (requestId != _productSearchRequestId) {
      return;
    }

    result.when(
      success: (items) {
        _productCandidates = items;
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

    final result = await repository.listNonStandardInventory();
    result.when(
      success: (items) {
        _nonStandardInventoryItems = items;
        _clearStaleNonStandardInventory();
        _nonStandardInventoryError = null;
      },
      failure: (failure) {
        _nonStandardInventoryItems = const [];
        _nonStandardInventoryError = failure.message;
      },
    );

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

    final result = await repository.listRecentDocuments(docType: 2);
    if (_selectedAction != selectedAction || !isReturnAction) {
      return;
    }

    result.when(
      success: (documents) {
        _returnSourceDocuments = _eligibleReturnSourceDocuments(documents);
        _returnSourceError = null;
      },
      failure: (failure) {
        _returnSourceDocuments = const [];
        _returnSourceError = failure.message;
      },
    );
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

    final documentsResult = await repository.listRecentDocuments(
      docType: _selectedDocumentTypeFilter,
    );

    documentsResult.when(
      success: (documents) {
        _recentDocuments = documents;
        _clearStaleReturnSourceDocument();
        _errorMessage = null;
      },
      failure: (failure) {
        _errorMessage = failure.message;
      },
    );

    final transactionsResult = await repository.listTransactions();

    transactionsResult.when(
      success: (transactions) {
        _transactions = transactions;
        _transactionError = null;
      },
      failure: (failure) {
        _transactionError = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();
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

    final invalidQuantity =
        quantity == null || (isStocktakeAction ? quantity < 0 : quantity <= 0);
    if (selectedProduct == null || invalidQuantity) {
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

    final nonStandardInventory = _selectedNonStandardInventory;
    if (isConversionAction && nonStandardInventory == null) {
      _formError = '请选择非标库存';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '单据服务未配置';
      notifyListeners();
      return false;
    }

    _isSubmitting = true;
    _formError = null;
    notifyListeners();

    final result = await repository.createDocument(
      CreateDocumentRequest(
        docType: _selectedAction.docType,
        typeLabel: _selectedAction.label,
        productId: selectedProduct.productId,
        productName: selectedProduct.productName,
        quantity: quantity,
        retailPrice: _selectedAction.docType == 2
            ? selectedProduct.retailPrice
            : null,
        toWarehouseId: isTransferAction ? targetWarehouse?.id : null,
        refDocId: isReturnAction ? returnSourceDocument?.id : null,
        actualQuantity: isStocktakeAction ? quantity : null,
        nonStdInventoryId: isConversionAction ? nonStandardInventory?.id : null,
      ),
    );

    var created = false;
    result.when(
      success: (document) {
        _recentDocuments = [
          _withSubmittedLineSummary(
            document: document,
            product: selectedProduct,
            quantity: quantity,
          ),
          ..._recentDocuments,
        ];
        _selectedProduct = null;
        _productQuery = '';
        _productCandidates = const [];
        _selectedNonStandardInventory = null;
        _selectedTargetWarehouse = null;
        _selectedReturnSourceDocument = null;
        _quantityText = '';
        _formError = null;
        created = true;
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );

    _isSubmitting = false;
    notifyListeners();
    return created;
  }

  DocumentRecord _withSubmittedLineSummary({
    required DocumentRecord document,
    required InventoryItem product,
    required int quantity,
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
          ? product.productName
          : document.productName,
      quantity: document.quantity == 0 ? quantity : document.quantity,
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
