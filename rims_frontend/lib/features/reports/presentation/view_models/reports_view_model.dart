import 'package:flutter/material.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/report_data.dart';
import '../../domain/repositories/reports_repository.dart';

final class ReportSummaryMetric {
  const ReportSummaryMetric({required this.label, required this.value});

  final String label;
  final String value;
}

final class ReportRanking {
  const ReportRanking({
    required this.name,
    required this.value,
    required this.amountLabel,
  });

  final String name;
  final double value;
  final String amountLabel;
}

final class InventoryBucket {
  const InventoryBucket({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}

final class ReportTurnoverItem {
  const ReportTurnoverItem({
    required this.name,
    required this.rateLabel,
    required this.detailLabel,
  });

  final String name;
  final String rateLabel;
  final String detailLabel;
}

final class ReportSlowMovingItem {
  const ReportSlowMovingItem({
    required this.name,
    required this.detailLabel,
    required this.lastSaleLabel,
  });

  final String name;
  final String detailLabel;
  final String lastSaleLabel;
}

final class ReportsViewModel extends ChangeNotifier {
  ReportsViewModel({
    this.repository,
    this.canViewFinancialMetrics = true,
    DateTime? today,
  }) : today = _dateOnly(today ?? DateTime.now());

  String _selectedPeriodLabel = '近7天';
  List<ReportSummaryMetric> _summaryMetrics = const [];
  List<double> _trendPoints = const [];
  List<ReportRanking> _rankings = const [];
  List<InventoryBucket> _inventoryBuckets = const [];
  List<ReportTurnoverItem> _turnoverItems = const [];
  List<ReportSlowMovingItem> _slowMovingItems = const [];
  int _slowMovingTotal = 0;
  bool _isLoading = false;
  String? _errorMessage;
  String? _inventoryReportErrorMessage;

  final ReportsRepository? repository;
  final bool canViewFinancialMetrics;
  final DateTime today;

  List<String> get periodLabels => const ['近7天', '近30天', '本月'];
  String get selectedPeriodLabel => _selectedPeriodLabel;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get inventoryReportErrorMessage => _inventoryReportErrorMessage;
  bool get isEmpty =>
      _summaryMetrics.isEmpty &&
      _trendPoints.isEmpty &&
      _rankings.isEmpty &&
      _inventoryBuckets.isEmpty &&
      _turnoverItems.isEmpty &&
      _slowMovingItems.isEmpty &&
      !_isLoading &&
      _errorMessage == null &&
      _inventoryReportErrorMessage == null;

  String get dateRangeLabel {
    final range = _currentRange;
    return '${_formatDate(range.start)} ~ ${_formatDate(range.end)}';
  }

  List<ReportSummaryMetric> get summaryMetrics => _summaryMetrics;

  List<double> get trendPoints => _trendPoints;

  List<ReportRanking> get rankings => _rankings;

  List<InventoryBucket> get inventoryBuckets => _inventoryBuckets;

  List<ReportTurnoverItem> get turnoverItems => _turnoverItems;

  List<ReportSlowMovingItem> get slowMovingItems => _slowMovingItems;
  int get slowMovingTotal => _slowMovingTotal;

  Future<void> load() async {
    final repository = this.repository;
    if (repository == null) {
      _clearData();
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _inventoryReportErrorMessage = null;
    notifyListeners();

    final range = _currentRange;
    Failure? failure;
    Failure? inventoryReportFailure;
    SalesStats? salesStats;
    if (canViewFinancialMetrics) {
      final statsResult = await repository.loadSalesStats(
        startDate: range.start,
        endDate: range.end,
      );
      statsResult.when(
        success: (data) => salesStats = data,
        failure: (value) => failure = value,
      );
      if (failure != null) {
        _finishFailure(failure!);
        return;
      }
    }

    List<SalesTrendPoint> trendPoints = const [];
    List<SalesRankingItem> rankingItems = const [];
    if (canViewFinancialMetrics) {
      final trendResult = await repository.loadSalesTrend(
        startDate: range.start,
        endDate: range.end,
      );
      trendResult.when(
        success: (data) => trendPoints = data,
        failure: (value) => failure = value,
      );
      if (failure != null) {
        _finishFailure(failure!);
        return;
      }

      final rankingResult = await repository.loadSalesRanking(
        startDate: range.start,
        endDate: range.end,
      );
      rankingResult.when(
        success: (data) => rankingItems = data,
        failure: (value) => failure = value,
      );
      if (failure != null) {
        _finishFailure(failure!);
        return;
      }
    }

    final overviewResult = await repository.loadInventoryOverview();
    List<InventoryOverviewItem> overviewItems = const [];
    overviewResult.when(
      success: (data) => overviewItems = data,
      failure: (value) => inventoryReportFailure ??= value,
    );

    final turnoverResult = await repository.loadInventoryTurnover(
      startDate: range.start,
      endDate: range.end,
    );
    List<InventoryTurnoverItem> turnoverItems = const [];
    turnoverResult.when(
      success: (data) => turnoverItems = data,
      failure: (value) => inventoryReportFailure ??= value,
    );

    final slowMovingResult = await repository.loadSlowMovingInventory(
      startDate: range.start,
      endDate: range.end,
    );
    List<SlowMovingInventoryItem> slowMovingItems = const [];
    var slowMovingTotal = 0;
    slowMovingResult.when(
      success: (data) {
        slowMovingItems = data.items;
        slowMovingTotal = data.total;
      },
      failure: (value) => inventoryReportFailure ??= value,
    );

    _summaryMetrics = salesStats == null
        ? const []
        : [
            ReportSummaryMetric(
              label: '销售额',
              value: _formatCurrency(salesStats?.revenue ?? 0),
            ),
            ReportSummaryMetric(
              label: '订单数',
              value: _formatInt(salesStats?.orderCount ?? 0),
            ),
            ReportSummaryMetric(
              label: '销量',
              value: _formatInt(salesStats?.quantity ?? 0),
            ),
          ];
    _trendPoints = canViewFinancialMetrics
        ? trendPoints.map((point) => point.amount).toList(growable: false)
        : const [];
    _rankings = canViewFinancialMetrics
        ? rankingItems
              .map(
                (item) => ReportRanking(
                  name: item.productName,
                  value: item.amount,
                  amountLabel: _formatCurrency(item.amount),
                ),
              )
              .toList(growable: false)
        : const [];
    _inventoryBuckets = overviewItems
        .map(
          (item) => InventoryBucket(
            label: item.label,
            value: item.value,
            color: _bucketColor(item.label),
          ),
        )
        .toList(growable: false);
    _turnoverItems = turnoverItems
        .map(
          (item) => ReportTurnoverItem(
            name: item.productName,
            rateLabel: '${item.turnoverRate.toStringAsFixed(2)} 次',
            detailLabel:
                '售出 ${_formatInt(item.soldQuantity)} / 均库 ${_formatInt(item.averageStockQuantity.round())}',
          ),
        )
        .toList(growable: false);
    _slowMovingItems = slowMovingItems
        .map(
          (item) => ReportSlowMovingItem(
            name: item.productName,
            detailLabel:
                '销量 ${_formatInt(item.salesQuantity)} / 库存 ${_formatInt(item.stockQuantity)}',
            lastSaleLabel: item.lastSaleAt == null || item.lastSaleAt!.isEmpty
                ? '暂无销售记录'
                : '最近销售 ${item.lastSaleAt}',
          ),
        )
        .toList(growable: false);
    _slowMovingTotal = slowMovingTotal;
    _isLoading = false;
    _errorMessage = null;
    _inventoryReportErrorMessage = inventoryReportFailure?.message;
    notifyListeners();
  }

  Future<void> selectPeriod(String label) async {
    if (!periodLabels.contains(label) || _selectedPeriodLabel == label) {
      return;
    }

    _selectedPeriodLabel = label;
    await load();
  }

  _ReportDateRange get _currentRange {
    return switch (_selectedPeriodLabel) {
      '近30天' => _ReportDateRange(
        start: today.subtract(const Duration(days: 29)),
        end: today,
      ),
      '本月' => _ReportDateRange(
        start: DateTime(today.year, today.month),
        end: today,
      ),
      _ => _ReportDateRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      ),
    };
  }

  void _finishFailure(Failure failure) {
    _clearData();
    _isLoading = false;
    _errorMessage = failure.message;
    notifyListeners();
  }

  void _clearData() {
    _summaryMetrics = const [];
    _trendPoints = const [];
    _rankings = const [];
    _inventoryBuckets = const [];
    _turnoverItems = const [];
    _slowMovingItems = const [];
    _slowMovingTotal = 0;
    _inventoryReportErrorMessage = null;
  }

  Color _bucketColor(String label) {
    return switch (label) {
      '正常库存' => AppColors.success,
      '低库存' => AppColors.warning,
      '超储' => AppColors.info,
      '无库存' => AppColors.error,
      _ => AppColors.primary,
    };
  }

  String _formatCurrency(double value) {
    return '¥${_formatInt(value.round())}';
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

  static DateTime _dateOnly(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

final class _ReportDateRange {
  const _ReportDateRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}
