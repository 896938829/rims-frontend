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

final class HomeDataFreshness {
  const HomeDataFreshness({
    required this.fetchedAt,
    required this.expiresAt,
    required this.hasCachedData,
  });

  final DateTime fetchedAt;
  final DateTime expiresAt;
  final bool hasCachedData;
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
  int _loadGeneration = 0;
  String? _errorMessage;
  String? _recentDocumentsErrorMessage;
  HomeDataFreshness? _dataFreshness;

  String get warehouseName => warehouse?.name ?? '未选择仓库';
  String get greeting {
    final name = user?.realName.isNotEmpty == true
        ? user!.realName
        : user?.username ?? '未登录用户';
    return '你好，$name';
  }

  bool get isLoading => _isLoading;
  int get loadGeneration => _loadGeneration;
  String? get errorMessage => _errorMessage;
  String? get recentDocumentsErrorMessage => _recentDocumentsErrorMessage;
  int get inventoryTotal => _inventoryTotal;
  int get inventoryAlertTotal => _inventoryAlertTotal;
  int get nonStandardInventoryTotal => _nonStandardInventoryTotal;
  int get recentDocumentsTotal => _recentDocumentsTotal;
  HomeDataFreshness? get dataFreshness => _dataFreshness;

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
    _loadGeneration += 1;
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    _isLoading = true;
    _errorMessage = null;
    _recentDocumentsErrorMessage = null;
    notifyListeners();

    Failure? failure;
    var inventoryItems = _inventoryItems;
    var inventoryOverviewItems = _inventoryOverviewItems;
    var recentDocuments = _recentDocuments;
    var inventoryAlertsLoaded = _inventoryAlertsLoaded;
    var nonStandardInventoryLoaded = _nonStandardInventoryLoaded;
    var inventoryTotal = _inventoryTotal;
    var inventoryAlertTotal = _inventoryAlertTotal;
    var nonStandardInventoryTotal = _nonStandardInventoryTotal;
    var recentDocumentsTotal = _recentDocumentsTotal;
    String? recentDocumentsErrorMessage;
    final freshness = <HomeDataFreshness>[];
    var freshnessComplete = true;
    var expectedFreshnessSlices = 0;

    bool isCurrent() => !_isDisposed && generation == _loadGeneration;

    void recordFreshness(HomeDataFreshness? value) {
      expectedFreshnessSlices += 1;
      if (value == null) {
        freshnessComplete = false;
      } else {
        freshness.add(value);
      }
    }

    final inventoryRepository = this.inventoryRepository;
    if (inventoryRepository == null) {
      inventoryItems = const [];
      inventoryAlertsLoaded = false;
      nonStandardInventoryLoaded = false;
      inventoryTotal = 0;
      inventoryAlertTotal = 0;
      nonStandardInventoryTotal = 0;
    } else {
      final inventoryResult = await inventoryRepository.listInventory();
      if (!isCurrent()) return;
      inventoryResult.when(
        success: (page) {
          inventoryItems = page.items;
          inventoryTotal = page.total;
          recordFreshness(_inventoryFreshness(inventoryRepository));
        },
        failure: (value) {
          failure ??= value;
          recordFreshness(null);
        },
      );

      final alertsResult = await inventoryRepository.listInventoryAlerts();
      if (!isCurrent()) return;
      alertsResult.when(
        success: (page) {
          inventoryAlertTotal = page.total;
          inventoryAlertsLoaded = true;
          recordFreshness(_inventoryFreshness(inventoryRepository));
        },
        failure: (_) => recordFreshness(null),
      );

      final nonStandardResult = await inventoryRepository
          .listNonStandardInventory();
      if (!isCurrent()) return;
      nonStandardResult.when(
        success: (page) {
          nonStandardInventoryTotal = page.total;
          nonStandardInventoryLoaded = true;
          recordFreshness(_inventoryFreshness(inventoryRepository));
        },
        failure: (_) => recordFreshness(null),
      );
    }

    final reportsRepository = this.reportsRepository;
    if (reportsRepository == null) {
      inventoryOverviewItems = const [];
    } else {
      final overviewResult = await reportsRepository.loadInventoryOverview();
      if (!isCurrent()) return;
      overviewResult.when(
        success: (items) {
          inventoryOverviewItems = items;
          recordFreshness(_reportFreshness(reportsRepository));
        },
        failure: (_) => recordFreshness(null),
      );
    }

    final documentsRepository = this.documentsRepository;
    if (documentsRepository == null) {
      recentDocuments = const [];
      recentDocumentsTotal = 0;
    } else {
      final documentsResult = await documentsRepository.listRecentDocuments();
      if (!isCurrent()) return;
      documentsResult.when(
        success: (page) {
          recentDocuments = page.items;
          recentDocumentsTotal = page.total;
          recordFreshness(_documentFreshness(documentsRepository));
        },
        failure: (value) {
          recentDocumentsErrorMessage = value.message;
          recordFreshness(null);
        },
      );
    }

    if (!isCurrent()) return;
    _inventoryItems = inventoryItems;
    _inventoryOverviewItems = inventoryOverviewItems;
    _recentDocuments = recentDocuments;
    _inventoryAlertsLoaded = inventoryAlertsLoaded;
    _nonStandardInventoryLoaded = nonStandardInventoryLoaded;
    _inventoryTotal = inventoryTotal;
    _inventoryAlertTotal = inventoryAlertTotal;
    _nonStandardInventoryTotal = nonStandardInventoryTotal;
    _recentDocumentsTotal = recentDocumentsTotal;
    _recentDocumentsErrorMessage = recentDocumentsErrorMessage;
    _dataFreshness =
        freshnessComplete &&
            expectedFreshnessSlices > 0 &&
            freshness.length == expectedFreshnessSlices
        ? _aggregateFreshness(freshness)
        : null;
    _isLoading = false;
    _errorMessage = failure?.message;
    notifyListeners();
  }

  HomeDataFreshness? _inventoryFreshness(InventoryRepository repository) {
    if (repository case final InventoryReadMetadata metadata) {
      final status = metadata.lastReadStatus;
      if (status != null) {
        return _freshness(status.fetchedAt, status.expiresAt, status.isCached);
      }
    }
    return null;
  }

  HomeDataFreshness? _documentFreshness(DocumentsRepository repository) {
    if (repository case final DocumentReadMetadata metadata) {
      final status = metadata.lastReadStatus;
      if (status != null) {
        return _freshness(status.fetchedAt, status.expiresAt, status.isCached);
      }
    }
    return null;
  }

  HomeDataFreshness? _reportFreshness(ReportsRepository repository) {
    if (repository case final ReportReadMetadata metadata) {
      final status = metadata.lastReadStatus;
      if (status != null) {
        return _freshness(status.fetchedAt, status.expiresAt, status.isCached);
      }
    }
    return null;
  }

  HomeDataFreshness _freshness(
    DateTime fetchedAt,
    DateTime expiresAt,
    bool cached,
  ) => HomeDataFreshness(
    fetchedAt: fetchedAt,
    expiresAt: expiresAt,
    hasCachedData: cached,
  );

  HomeDataFreshness _aggregateFreshness(List<HomeDataFreshness> values) {
    var fetchedAt = values.first.fetchedAt;
    var expiresAt = values.first.expiresAt;
    var hasCachedData = false;
    for (final value in values) {
      if (value.fetchedAt.isBefore(fetchedAt)) fetchedAt = value.fetchedAt;
      if (value.expiresAt.isBefore(expiresAt)) expiresAt = value.expiresAt;
      hasCachedData = hasCachedData || value.hasCachedData;
    }
    return HomeDataFreshness(
      fetchedAt: fetchedAt,
      expiresAt: expiresAt,
      hasCachedData: hasCachedData,
    );
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
