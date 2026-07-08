import 'package:flutter/foundation.dart';

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
  bool _isLoadingTransactions = false;
  bool _isLookingUpBarcode = false;
  bool _isSavingSettings = false;
  String? _errorMessage;
  String? _transactionError;
  String? _barcodeLookupError;
  String? _settingsError;

  String get query => _query;
  String get selectedTab => _selectedTab;
  bool get isLoading => _isLoading;
  bool get isLoadingTransactions => _isLoadingTransactions;
  bool get isLookingUpBarcode => _isLookingUpBarcode;
  bool get isSavingSettings => _isSavingSettings;
  String? get errorMessage => _errorMessage;
  String? get transactionError => _transactionError;
  String? get barcodeLookupError => _barcodeLookupError;
  String? get settingsError => _settingsError;
  bool get isEmpty => _items.isEmpty && !_isLoading && _errorMessage == null;
  List<InventoryItem> get items => _items;
  List<TransactionRecord> get transactions =>
      List<TransactionRecord>.unmodifiable(_transactions);
  InventoryItem? get selectedItem => _selectedItem;

  List<String> get tabs => const ['商品', '标准', '低库存', '非标', '停用'];

  List<InventoryMetric> get metrics => [
    InventoryMetric(label: 'SKU数', value: _formatInt(_items.length)),
    InventoryMetric(
      label: '总库存',
      value: _formatInt(
        _items.fold<int>(0, (sum, item) => sum + item.stockQuantity),
      ),
    ),
    InventoryMetric(
      label: '低库存',
      value: _formatInt(_items.where(_isLowStock).length),
    ),
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
    final repository = this.repository;
    if (repository == null) {
      _items = const [];
      _errorMessage = null;
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await repository.listInventory(
      keyword: _query.trim(),
      page: page,
    );

    result.when(
      success: (items) {
        _items = items;
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

    final result = await repository.listTransactions();

    result.when(
      success: (transactions) {
        _transactions = transactions;
        _transactionError = null;
      },
      failure: (failure) {
        _transactions = const [];
        _transactionError = failure.message;
      },
    );

    _isLoadingTransactions = false;
    notifyListeners();
  }

  Future<void> updateQuery(String value) async {
    if (_query == value) {
      return;
    }

    _query = value;
    await load();
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
