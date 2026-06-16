import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

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

final class ReportsViewModel {
  const ReportsViewModel();

  String get dateRangeLabel => '2024-05-12 ~ 2024-05-18';

  List<double> get trendPoints => const [
    12800,
    15600,
    14200,
    18800,
    17600,
    21500,
    23800,
  ];

  List<ReportRanking> get rankings => const [
    ReportRanking(name: '矿泉水 550ml', value: 23800, amountLabel: '¥23,800'),
    ReportRanking(name: '纸巾抽纸 3层', value: 19600, amountLabel: '¥19,600'),
    ReportRanking(name: '洗衣液 2kg', value: 16800, amountLabel: '¥16,800'),
    ReportRanking(name: '洗发水 400ml', value: 12500, amountLabel: '¥12,500'),
    ReportRanking(name: '牙膏 120g', value: 9200, amountLabel: '¥9,200'),
  ];

  List<InventoryBucket> get inventoryBuckets => const [
    InventoryBucket(label: '正常库存', value: 72, color: AppColors.success),
    InventoryBucket(label: '低库存', value: 14, color: AppColors.warning),
    InventoryBucket(label: '超储', value: 9, color: AppColors.info),
    InventoryBucket(label: '无库存', value: 5, color: AppColors.error),
  ];
}
