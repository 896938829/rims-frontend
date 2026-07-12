import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../domain/entities/inventory_item.dart';
import '../../domain/repositories/inventory_repository.dart';

final class InventoryMetric {
  const InventoryMetric({required this.label, required this.value});

  final String label;
  final String value;
}

final class InventoryViewModel extends ChangeNotifier {
  InventoryViewModel({
    this.repository,
    this.documentsRepository,
    this.warehouseName = '未选择仓库',
    this.canManageInventorySettings = false,
  });

  static const String allProductsTab = '商品';

  final InventoryRepository? repository;
  final DocumentsRepository? documentsRepository;
  final String warehouseName;
  final bool canManageInventorySettings;
  List<InventoryItem> _items = const [];
  List<TransactionRecord> _transactions = const [];
  InventoryItem? _selectedItem;
  String _query = '';
  String _selectedTab = allProductsTab;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingTransactions = false;
  bool _isLookingUpBarcode = false;
  bool _isSavingSettings = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _transactionError;
  String? _barcodeLookupError;
  String? _settingsError;
  Failure? _loadMoreFailure;
  int _page = 0;
  int _total = 0;
  int _queryGeneration = 0;
  int? _loadingMoreGeneration;
  bool _reachedEnd = false;

  String get query => _query;
  String get selectedTab => _selectedTab;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingTransactions => _isLoadingTransactions;
  bool get isLookingUpBarcode => _isLookingUpBarcode;
  bool get isSavingSettings => _isSavingSettings;
  String? get errorMessage => _errorMessage;
  String? get transactionError => _transactionError;
  String? get barcodeLookupError => _barcodeLookupError;
  String? get settingsError => _settingsError;
  Failure? get loadMoreFailure => _loadMoreFailure;
  int get loadedCount => _items.length;
  int get total => _total;
  bool get hasMore => _page > 0 && !_reachedEnd && loadedCount < _total;
  bool get isEmpty => _items.isEmpty && !_isLoading && _errorMessage == null;
  List<InventoryItem> get items => _items;
  List<TransactionRecord> get transactions =>
      List<TransactionRecord>.unmodifiable(_transactions);
  InventoryItem? get selectedItem => _selectedItem;

  List<String> get tabs => const ['商品', '标准', '低库存', '非标', '停用'];

  List<InventoryMetric> get metrics => [
    InventoryMetric(label: '已加载', value: _formatInt(loadedCount)),
    InventoryMetric(label: '总条目', value: _formatInt(_total)),
    InventoryMetric(label: '加载进度', value: '$loadedCount/$_total'),
  ];

  List<InventoryItem> get visibleItems {
    final normalizedQuery = _query.trim().toLowerCase();

    return _items
        .where((item) {
          final matchesTab = switch (_selectedTab) {
            '标准' => item.statusLabel == '标准',
            '低库存' => _isLowStock(item),
            '非标' => item.statusLabel == '非标',
            '停用' => _isDisabled(item),
            _ => true,
          };
          final matchesQuery =
              normalizedQuery.isEmpty ||
              item.productName.toLowerCase().contains(normalizedQuery) ||
              item.sku.toLowerCase().contains(normalizedQuery);

          return matchesTab && matchesQuery;
        })
        .toList(growable: false);
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  List<TransactionRecord> transactionsFor(InventoryItem item) {
    return _transactions
        .where((transaction) => transaction.productId == item.productId)
        .toList(growable: false);
  }

  bool _isLowStock(InventoryItem item) {
    return !_isDisabled(item) &&
        (item.statusLabel == '低库存' || item.availableQuantity <= 5);
  }

  bool _isDisabled(InventoryItem item) {
    return item.status == 0 || item.statusLabel == '停用';
  }

  Future<void> load({int page = 1}) async {
    final generation = ++_queryGeneration;
    final repository = this.repository;
    if (repository == null) {
      _items = const [];
      _page = 0;
      _total = 0;
      _reachedEnd = false;
      _errorMessage = null;
      _loadMoreFailure = null;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _isLoadingMore = false;
    _loadingMoreGeneration = null;
    _page = 0;
    _total = 0;
    _reachedEnd = false;
    _errorMessage = null;
    _loadMoreFailure = null;
    notifyListeners();

    final keyword = _query.trim();
    final result = await repository.listInventory(keyword: keyword, page: page);
    if (_isDisposed) return;

    if (generation != _queryGeneration || keyword != _query.trim()) {
      return;
    }
    result.when(
      success: (pageData) {
        _items = _mergeInventoryItems(const [], pageData.items);
        _page = pageData.page;
        _total = pageData.total;
        _reachedEnd = pageData.items.isEmpty || !pageData.hasNextPage;
        _errorMessage = null;
      },
      failure: (failure) {
        _errorMessage = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();

    await loadTransactions();
  }

  Future<void> loadMore() async {
    final repository = this.repository;
    if (repository == null || _isLoading || _isLoadingMore || !hasMore) {
      return;
    }

    final generation = _queryGeneration;
    final keyword = _query.trim();
    final requestedPage = _page + 1;
    _isLoadingMore = true;
    _loadingMoreGeneration = generation;
    _loadMoreFailure = null;
    notifyListeners();

    final result = await repository.listInventory(
      keyword: keyword,
      page: requestedPage,
    );
    if (_isDisposed) return;
    if (generation != _queryGeneration || keyword != _query.trim()) {
      if (_loadingMoreGeneration == generation) {
        _isLoadingMore = false;
        _loadingMoreGeneration = null;
        notifyListeners();
      }
      return;
    }

    result.when(
      success: (pageData) {
        _items = _mergeInventoryItems(_items, pageData.items);
        _page = pageData.page;
        _total = pageData.total;
        _reachedEnd = pageData.items.isEmpty || !pageData.hasNextPage;
        _loadMoreFailure = null;
      },
      failure: (failure) {
        _loadMoreFailure = failure;
      },
    );
    if (_loadingMoreGeneration == generation) {
      _isLoadingMore = false;
      _loadingMoreGeneration = null;
    }
    notifyListeners();
  }

  Future<void> retryLoadMore() => loadMore();

  Future<void> loadTransactions() async {
    final repository = documentsRepository;
    if (repository == null) {
      _transactions = const [];
      _transactionError = null;
      _isLoadingTransactions = false;
      notifyListeners();
      return;
    }

    _isLoadingTransactions = true;
    _transactionError = null;
    notifyListeners();

    final transactions = <TransactionRecord>[];
    var pageNumber = 1;
    while (pageNumber > 0) {
      final result = await repository.listTransactions(page: pageNumber);
      if (_isDisposed) return;
      switch (result) {
        case Success(:final data):
          transactions.addAll(data.items);
          pageNumber = data.items.isEmpty || !data.hasNextPage
              ? 0
              : data.nextPage;
        case FailureResult(:final failure):
          _transactions = const [];
          _transactionError = failure.message;
          pageNumber = 0;
      }
    }
    if (_transactionError == null) {
      _transactions = _mergeTransactions(transactions);
    }

    _isLoadingTransactions = false;
    notifyListeners();
  }

  List<TransactionRecord> _mergeTransactions(
    List<TransactionRecord> transactions,
  ) {
    final byId = <int, TransactionRecord>{};
    for (final transaction in transactions) {
      byId[transaction.id] = transaction;
    }
    return List.unmodifiable(byId.values);
  }

  Future<void> updateQuery(String value) async {
    if (_query == value) {
      return;
    }

    _query = value;
    await load();
  }

  List<InventoryItem> _mergeInventoryItems(
    List<InventoryItem> existing,
    List<InventoryItem> incoming,
  ) {
    final merged = List<InventoryItem>.of(existing);
    final indexes = <int, int>{
      for (var index = 0; index < merged.length; index += 1)
        merged[index].id: index,
    };
    for (final item in incoming) {
      final index = indexes[item.id];
      if (index == null) {
        indexes[item.id] = merged.length;
        merged.add(item);
      } else {
        merged[index] = item;
      }
    }
    return List<InventoryItem>.unmodifiable(merged);
  }

  Future<InventoryItem?> lookupBarcode(String barcode) async {
    final trimmedBarcode = barcode.trim();
    if (trimmedBarcode.isEmpty) {
      _barcodeLookupError = '请输入条码';
      notifyListeners();
      return null;
    }

    final repository = this.repository;
    if (repository == null) {
      _barcodeLookupError = '库存服务不可用';
      notifyListeners();
      return null;
    }

    _isLookingUpBarcode = true;
    _barcodeLookupError = null;
    notifyListeners();

    final result = await repository.findProductByBarcode(trimmedBarcode);
    if (_isDisposed) return null;
    InventoryItem? foundItem;
    result.when(
      success: (item) {
        foundItem = item;
        _selectedItem = item;
        if (!_items.any(
          (existing) =>
              existing.id == item.id && existing.productId == item.productId,
        )) {
          _items = [item, ..._items];
        }
      },
      failure: (failure) {
        _barcodeLookupError = failure.message;
      },
    );

    _isLookingUpBarcode = false;
    notifyListeners();
    return foundItem;
  }

  void selectTab(String tab) {
    if (!tabs.contains(tab) || _selectedTab == tab) {
      return;
    }

    _selectedTab = tab;
    notifyListeners();
  }

  void selectItem(InventoryItem item) {
    _selectedItem = item;
    _settingsError = null;
    notifyListeners();
  }

  Future<bool> updateSelectedItemSettings({
    int? alertThreshold,
    int? status,
  }) async {
    if (!canManageInventorySettings) {
      _settingsError = '无权限调整库存设置';
      notifyListeners();
      return false;
    }

    final item = _selectedItem;
    if (item == null) {
      _settingsError = '请选择库存商品';
      notifyListeners();
      return false;
    }

    if (item.id <= 0) {
      _settingsError = '该商品暂无库存记录';
      notifyListeners();
      return false;
    }

    if (alertThreshold == null && status == null) {
      _settingsError = '请填写要保存的库存设置';
      notifyListeners();
      return false;
    }

    if (alertThreshold != null && alertThreshold < 0) {
      _settingsError = '预警阈值不能小于 0';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _settingsError = '库存服务不可用';
      notifyListeners();
      return false;
    }

    _isSavingSettings = true;
    _settingsError = null;
    notifyListeners();

    var saved = false;
    final result = await repository.updateInventorySettings(
      inventoryId: item.id,
      alertThreshold: alertThreshold,
      status: status,
    );
    if (_isDisposed) return false;

    result.when(
      success: (updatedItem) {
        _selectedItem = updatedItem;
        _items = _items
            .map(
              (candidate) =>
                  candidate.id == updatedItem.id ? updatedItem : candidate,
            )
            .toList(growable: false);
        _settingsError = null;
        saved = true;
      },
      failure: (failure) {
        _settingsError = failure.message;
      },
    );

    _isSavingSettings = false;
    notifyListeners();
    return saved;
  }

  void clearSelectedItem() {
    if (_selectedItem == null) {
      return;
    }

    _selectedItem = null;
    notifyListeners();
  }

  String _formatInt(int value) {
    final text = value.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < text.length; index += 1) {
      if (index > 0 && (text.length - index) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(text[index]);
    }

    return buffer.toString();
  }
}
