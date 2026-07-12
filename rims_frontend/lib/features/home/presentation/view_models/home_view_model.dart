import 'package:flutter/foundation.dart';

import '../../../../core/navigation/app_tab.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/resources/app_icons.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../reports/domain/entities/report_data.dart';
import '../../../reports/domain/repositories/reports_repository.dart';

final class HomeMetric {
  const HomeMetric({required this.label, required this.value, this.delta});

  final String label;
  final String value;
  final String? delta;
}

final class HomeQuickAction {
  const HomeQuickAction({
    required this.label,
    required this.icon,
    required this.targetTab,
    this.documentActionLabel,
    this.requestsScanner = false,
  });

  final String label;
  final String icon;
  final AppTab targetTab;
  final String? documentActionLabel;
  final bool requestsScanner;
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
    this.reportsRepository,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final InventoryRepository? inventoryRepository;
  final DocumentsRepository? documentsRepository;
  final ReportsRepository? reportsRepository;
  List<InventoryItem> _inventoryItems = const [];
  List<InventoryOverviewItem> _inventoryOverviewItems = const [];
  List<DocumentRecord> _recentDocuments = const [];
  bool _inventoryAlertsLoaded = false;
  bool _nonStandardInventoryLoaded = false;
  int _inventoryTotal = 0;
  int _inventoryAlertTotal = 0;
  int _nonStandardInventoryTotal = 0;
  int _recentDocumentsTotal = 0;
  bool _isLoading = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _recentDocumentsErrorMessage;

  String get warehouseName => warehouse?.name ?? '未选择仓库';
  String get greeting {
    final name = user?.realName.isNotEmpty == true
        ? user!.realName
        : user?.username ?? '未登录用户';
    return '你好，$name';
  }

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get recentDocumentsErrorMessage => _recentDocumentsErrorMessage;
  int get inventoryTotal => _inventoryTotal;
  int get inventoryAlertTotal => _inventoryAlertTotal;
  int get nonStandardInventoryTotal => _nonStandardInventoryTotal;
  int get recentDocumentsTotal => _recentDocumentsTotal;

  List<HomeMetric> get metrics => [
    HomeMetric(
      label: '商品数',
      value: _formatInt(_overviewInt('商品数') ?? _inventoryTotal),
    ),
    HomeMetric(label: '库存总量', value: _formatInt(_overviewInt('库存总量') ?? 0)),
    HomeMetric(
      label: '预警数量',
      value: _formatInt(_overviewInt('预警数量') ?? _inventoryAlertCount),
    ),
  ];

  static const List<HomeQuickAction> _quickActions = [
    HomeQuickAction(
      label: '扫码销售',
      icon: AppIcons.actionScan,
      targetTab: AppTab.documents,
      documentActionLabel: '销售出库',
      requestsScanner: true,
    ),
    HomeQuickAction(
      label: '退货',
      icon: AppIcons.actionReturn,
      targetTab: AppTab.documents,
      documentActionLabel: '退货入库',
    ),
    HomeQuickAction(
      label: '入库',
      icon: AppIcons.actionInbound,
      targetTab: AppTab.documents,
      documentActionLabel: '采购入库',
    ),
    HomeQuickAction(
      label: '调拨',
      icon: AppIcons.actionTransfer,
      targetTab: AppTab.documents,
      documentActionLabel: '调拨单',
    ),
    HomeQuickAction(
      label: '盘点',
      icon: AppIcons.actionStocktake,
      targetTab: AppTab.documents,
      documentActionLabel: '盘点单',
    ),
    HomeQuickAction(
      label: '转标准',
      icon: AppIcons.actionScan,
      targetTab: AppTab.documents,
      documentActionLabel: '转标准',
    ),
  ];

  List<HomeQuickAction> get quickActions => _quickActions
      .where(
        (action) => user?.isAdmin == true || !_isAdminOnlyQuickAction(action),
      )
      .toList(growable: false);

  List<InventoryWarning> get warnings => [
    if (_inventoryAlertCount > 0)
      InventoryWarning(
        label: '低库存',
        count: _inventoryAlertCount,
        level: 'warning',
      ),
    if (_nonStandardCount > 0)
      InventoryWarning(label: '非标库存', count: _nonStandardCount, level: 'info'),
  ];

  List<DocumentRecord> get recentDocuments => _recentDocuments;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    _recentDocumentsErrorMessage = null;
    notifyListeners();

    Failure? failure;
    final inventoryRepository = this.inventoryRepository;
    if (inventoryRepository == null) {
      _inventoryItems = const [];
      _inventoryAlertsLoaded = false;
      _nonStandardInventoryLoaded = false;
      _inventoryTotal = 0;
      _inventoryAlertTotal = 0;
      _nonStandardInventoryTotal = 0;
    } else {
      final inventoryResult = await inventoryRepository.listInventory();
      if (_isDisposed) return;
      inventoryResult.when(
        success: (page) {
          _inventoryItems = page.items;
          _inventoryTotal = page.total;
        },
        failure: (value) {
          failure ??= value;
        },
      );

      final alertsResult = await inventoryRepository.listInventoryAlerts();
      if (_isDisposed) return;
      alertsResult.when(
        success: (page) {
          _inventoryAlertTotal = page.total;
          _inventoryAlertsLoaded = true;
        },
        failure: (_) {},
      );

      final nonStandardResult = await inventoryRepository
          .listNonStandardInventory();
      if (_isDisposed) return;
      nonStandardResult.when(
        success: (page) {
          _nonStandardInventoryTotal = page.total;
          _nonStandardInventoryLoaded = true;
        },
        failure: (_) {},
      );
    }

    final reportsRepository = this.reportsRepository;
    if (reportsRepository == null) {
      _inventoryOverviewItems = const [];
    } else {
      final overviewResult = await reportsRepository.loadInventoryOverview();
      if (_isDisposed) return;
      overviewResult.when(
        success: (items) => _inventoryOverviewItems = items,
        failure: (_) {},
      );
    }

    final documentsRepository = this.documentsRepository;
    if (documentsRepository == null) {
      _recentDocuments = const [];
      _recentDocumentsTotal = 0;
      _recentDocumentsErrorMessage = null;
    } else {
      final documentsResult = await documentsRepository.listRecentDocuments();
      if (_isDisposed) return;
      documentsResult.when(
        success: (page) {
          _recentDocuments = page.items;
          _recentDocumentsTotal = page.total;
          _recentDocumentsErrorMessage = null;
        },
        failure: (value) {
          _recentDocumentsErrorMessage = value.message;
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

  int get _inventoryAlertCount {
    return _inventoryAlertsLoaded ? _inventoryAlertTotal : _lowStockCount;
  }

  int get _nonStandardCount {
    return _nonStandardInventoryLoaded
        ? _nonStandardInventoryTotal
        : _inventoryItems.where((item) => item.statusLabel == '非标').length;
  }

  int? _overviewInt(String label) {
    for (final item in _inventoryOverviewItems) {
      if (item.label == label) {
        return item.value.round();
      }
    }

    return null;
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

  bool _isAdminOnlyQuickAction(HomeQuickAction action) {
    return action.documentActionLabel == '调拨单' ||
        action.documentActionLabel == '转标准';
  }
}
