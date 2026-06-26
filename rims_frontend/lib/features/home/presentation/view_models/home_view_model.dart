import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/resources/app_icons.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';

final class HomeMetric {
  const HomeMetric({required this.label, required this.value, this.delta});

  final String label;
  final String value;
  final String? delta;
}

final class HomeQuickAction {
  const HomeQuickAction({required this.label, required this.icon});

  final String label;
  final String icon;
}

final class InventoryWarning {
  const InventoryWarning({
    required this.label,
    required this.count,
    required this.level,
  });

  final String label;
  final int count;
  final String level;
}

final class HomeViewModel extends ChangeNotifier {
  HomeViewModel({
    this.user,
    this.warehouse,
    this.inventoryRepository,
    this.documentsRepository,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final InventoryRepository? inventoryRepository;
  final DocumentsRepository? documentsRepository;
  List<InventoryItem> _inventoryItems = const [];
  List<DocumentRecord> _recentDocuments = const [];
  bool _isLoading = false;
  String? _errorMessage;

  String get warehouseName => warehouse?.name ?? '未选择仓库';
  String get greeting {
    final name = user?.realName.isNotEmpty == true
        ? user!.realName
        : user?.username ?? '未登录用户';
    return 'Good morning, $name';
  }

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  List<HomeMetric> get metrics => [
    HomeMetric(label: '商品数', value: _formatInt(_inventoryItems.length)),
    HomeMetric(
      label: '库存总量',
      value: _formatInt(
        _inventoryItems.fold<int>(0, (sum, item) => sum + item.stockQuantity),
      ),
    ),
    HomeMetric(label: '预警数量', value: _formatInt(_lowStockCount)),
  ];

  List<HomeQuickAction> get quickActions => const [
    HomeQuickAction(label: '扫码销售', icon: AppIcons.actionScan),
    HomeQuickAction(label: '退货', icon: AppIcons.actionReturn),
    HomeQuickAction(label: '入库', icon: AppIcons.actionInbound),
    HomeQuickAction(label: '调拨', icon: AppIcons.actionTransfer),
  ];

  List<InventoryWarning> get warnings => [
    if (_lowStockCount > 0)
      InventoryWarning(label: '低库存', count: _lowStockCount, level: 'warning'),
    if (_nonStandardCount > 0)
      InventoryWarning(label: '非标库存', count: _nonStandardCount, level: 'info'),
  ];

  List<DocumentRecord> get recentDocuments => _recentDocuments;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    Failure? failure;
    final inventoryRepository = this.inventoryRepository;
    if (inventoryRepository == null) {
      _inventoryItems = const [];
    } else {
      final inventoryResult = await inventoryRepository.listInventory();
      inventoryResult.when(
        success: (items) => _inventoryItems = items,
        failure: (value) {
          _inventoryItems = const [];
          failure ??= value;
        },
      );
    }

    final documentsRepository = this.documentsRepository;
    if (documentsRepository == null) {
      _recentDocuments = const [];
    } else {
      final documentsResult = await documentsRepository.listRecentDocuments();
      documentsResult.when(
        success: (documents) => _recentDocuments = documents,
        failure: (value) {
          _recentDocuments = const [];
          failure ??= value;
        },
      );
    }

    _isLoading = false;
    _errorMessage = failure?.message;
    notifyListeners();
  }

  int get _lowStockCount {
    return _inventoryItems
        .where(
          (item) => item.statusLabel == '低库存' || item.availableQuantity <= 5,
        )
        .length;
  }

  int get _nonStandardCount {
    return _inventoryItems.where((item) => item.statusLabel == '非标').length;
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
