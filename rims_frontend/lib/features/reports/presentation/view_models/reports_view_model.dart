import 'package:flutter/material.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/report_data.dart';
import '../../domain/repositories/reports_repository.dart';

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

final class ReportsViewModel extends ChangeNotifier {
  ReportsViewModel({this.repository, DateTime? today})
    : today = _dateOnly(today ?? DateTime.now());

  String _selectedPeriodLabel = '近7天';
  List<double> _trendPoints = const [];
  List<ReportRanking> _rankings = const [];
  List<InventoryBucket> _inventoryBuckets = const [];
  bool _isLoading = false;
  String? _errorMessage;

  final ReportsRepository? repository;
  final DateTime today;

  List<String> get periodLabels => const ['近7天', '近30天', '本月'];
  String get selectedPeriodLabel => _selectedPeriodLabel;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isEmpty =>
      _trendPoints.isEmpty &&
      _rankings.isEmpty &&
      _inventoryBuckets.isEmpty &&
      !_isLoading &&
      _errorMessage == null;

  String get dateRangeLabel {
    final range = _currentRange;
    return '${_formatDate(range.start)} ~ ${_formatDate(range.end)}';
  }

  List<double> get trendPoints => _trendPoints;

  List<ReportRanking> get rankings => _rankings;

  List<InventoryBucket> get inventoryBuckets => _inventoryBuckets;

  Future<void> load() async {
    final repository = this.repository;
    if (repository == null) {
      _clearData();
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final range = _currentRange;
    final trendResult = await repository.loadSalesTrend(
      startDate: range.start,
      endDate: range.end,
    );
    Failure? failure;
    List<SalesTrendPoint> trendPoints = const [];
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
    List<SalesRankingItem> rankingItems = const [];
    rankingResult.when(
      success: (data) => rankingItems = data,
      failure: (value) => failure = value,
    );
    if (failure != null) {
      _finishFailure(failure!);
      return;
    }

    final overviewResult = await repository.loadInventoryOverview();
    List<InventoryOverviewItem> overviewItems = const [];
    overviewResult.when(
      success: (data) => overviewItems = data,
      failure: (value) => failure = value,
    );
    if (failure != null) {
      _finishFailure(failure!);
      return;
    }

    _trendPoints = trendPoints
        .map((point) => point.amount)
        .toList(growable: false);
    _rankings = rankingItems
        .map(
          (item) => ReportRanking(
            name: item.productName,
            value: item.amount,
            amountLabel: _formatCurrency(item.amount),
          ),
        )
        .toList(growable: false);
    _inventoryBuckets = overviewItems
        .map(
          (item) => InventoryBucket(
            label: item.label,
            value: item.value,
            color: _bucketColor(item.label),
          ),
        )
        .toList(growable: false);
    _isLoading = false;
    _errorMessage = null;
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
    _trendPoints = const [];
    _rankings = const [];
    _inventoryBuckets = const [];
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
