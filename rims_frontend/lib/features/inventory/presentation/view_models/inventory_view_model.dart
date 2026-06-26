import 'package:flutter/foundation.dart';

import '../../domain/entities/inventory_item.dart';
import '../../domain/repositories/inventory_repository.dart';

final class InventoryMetric {
  const InventoryMetric({required this.label, required this.value});

  final String label;
  final String value;
}

final class InventoryViewModel extends ChangeNotifier {
  InventoryViewModel({this.repository, this.warehouseName = '未选择仓库'});

  static const String allProductsTab = '商品';

  final InventoryRepository? repository;
  final String warehouseName;
  List<InventoryItem> _items = const [];
  String _query = '';
  String _selectedTab = allProductsTab;
  bool _isLoading = false;
  String? _errorMessage;

  String get query => _query;
  String get selectedTab => _selectedTab;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isEmpty => _items.isEmpty && !_isLoading && _errorMessage == null;
  List<InventoryItem> get items => _items;

  List<String> get tabs => const ['标准', '商品', '非标'];

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
      value: _formatInt(
        _items
            .where(
              (item) =>
                  item.statusLabel == '低库存' || item.availableQuantity <= 5,
            )
            .length,
      ),
    ),
  ];

  List<InventoryItem> get visibleItems {
    final normalizedQuery = _query.trim().toLowerCase();

    return _items
        .where((item) {
          final matchesTab = switch (_selectedTab) {
            '标准' => item.statusLabel == '标准',
            '非标' => item.statusLabel == '非标',
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
        _items = const [];
        _errorMessage = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateQuery(String value) async {
    if (_query == value) {
      return;
    }

    _query = value;
    await load();
  }

  void selectTab(String tab) {
    if (!tabs.contains(tab) || _selectedTab == tab) {
      return;
    }

    _selectedTab = tab;
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
