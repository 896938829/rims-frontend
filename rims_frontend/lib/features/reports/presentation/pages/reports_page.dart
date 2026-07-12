import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_mini_charts.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../domain/repositories/reports_repository.dart';
import '../view_models/reports_view_model.dart';
import '../widgets/report_ranking_bar.dart';

final class ReportsPage extends StatefulWidget {
  const ReportsPage({
    this.viewModel,
    this.repository,
    this.eventBus,
    this.canViewFinancialMetrics = true,
    super.key,
  });

  final ReportsViewModel? viewModel;
  final ReportsRepository? repository;
  final AppEventBus? eventBus;
  final bool canViewFinancialMetrics;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

final class _ReportsPageState extends State<ReportsPage> {
  late final ReportsViewModel viewModel;
  late final bool _ownsViewModel;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        ReportsViewModel(
          repository: widget.repository,
          canViewFinancialMetrics: widget.canViewFinancialMetrics,
        );

    if (_ownsViewModel) {
      unawaited(viewModel.load());
    }
    _subscribeToRefreshEvents();
  }

  @override
  void didUpdateWidget(covariant ReportsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.eventBus != oldWidget.eventBus) {
      unawaited(_refreshSubscription?.cancel());
      _subscribeToRefreshEvents();
    }
  }

  @override
  void dispose() {
    unawaited(_refreshSubscription?.cancel());
    if (_ownsViewModel) {
      viewModel.dispose();
    }

    super.dispose();
  }

  void _subscribeToRefreshEvents() {
    _refreshSubscription = widget.eventBus
        ?.on<GlobalRefreshRequestedEvent>()
        .listen((_) => unawaited(viewModel.load()));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        return RimsPageScaffold(
          key: const Key('tab-body-reports'),
          child: ListView(
            children: [
              Text('报表', style: AppTextStyles.headingLarge),
              const SizedBox(height: 4),
              Text(viewModel.dateRangeLabel, style: AppTextStyles.bodySmall),
              if (viewModel.cacheStatusLabel case final label?) ...[
                const SizedBox(height: 8),
                Row(
                  key: const Key('reports-cache-status'),
                  children: [
                    const Icon(
                      Icons.cloud_off_outlined,
                      size: 16,
                      color: AppColors.warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              _PeriodSelector(viewModel: viewModel),
              const SizedBox(height: 18),
              if (viewModel.isLoading)
                RimsCard(
                  child: Text(
                    '正在加载报表...',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else if (viewModel.errorMessage != null)
                RimsCard(
                  child: Column(
                    children: [
                      Text(
                        viewModel.errorMessage!,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: viewModel.isLoading
                            ? null
                            : () => unawaited(viewModel.load()),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              else if (viewModel.isEmpty)
                RimsCard(
                  child: Text(
                    '暂无报表数据',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else ...[
                if (viewModel.summaryMetrics.isNotEmpty) ...[
                  const RimsSectionHeader(title: '销售统计'),
                  const SizedBox(height: 10),
                  _SummaryMetrics(metrics: viewModel.summaryMetrics),
                  const SizedBox(height: 20),
                ],
                if (viewModel.trendPoints.isNotEmpty) ...[
                  const RimsSectionHeader(title: '销售趋势（元）'),
                  const SizedBox(height: 10),
                  RimsCard(child: RimsLineChart(values: viewModel.trendPoints)),
                  const SizedBox(height: 20),
                ],
                if (viewModel.rankings.isNotEmpty) ...[
                  const RimsSectionHeader(title: '商品排行（销售额）'),
                  const SizedBox(height: 10),
                  RimsCard(child: _RankingList(rankings: viewModel.rankings)),
                  const SizedBox(height: 20),
                ],
                if (viewModel.inventoryReportErrorMessage != null) ...[
                  RimsCard(
                    child: Text(
                      viewModel.inventoryReportErrorMessage!,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                const RimsSectionHeader(title: '库存概览'),
                const SizedBox(height: 10),
                RimsCard(
                  child: _InventoryOverview(
                    buckets: viewModel.inventoryBuckets,
                  ),
                ),
                const SizedBox(height: 20),
                const RimsSectionHeader(title: '库存周转'),
                const SizedBox(height: 10),
                RimsCard(child: _TurnoverList(items: viewModel.turnoverItems)),
                const SizedBox(height: 20),
                const RimsSectionHeader(title: '滞销商品'),
                const SizedBox(height: 10),
                RimsCard(
                  child: _SlowMovingList(items: viewModel.slowMovingItems),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

final class _TurnoverList extends StatelessWidget {
  const _TurnoverList({required this.items});

  final List<ReportTurnoverItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Text('暂无周转数据', style: AppTextStyles.bodySmall);
    }

    return Column(
      children: [
        for (final item in items) ...[
          _ReportInsightRow(
            title: item.name,
            value: item.rateLabel,
            subtitle: item.detailLabel,
          ),
          if (item != items.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

final class _SlowMovingList extends StatelessWidget {
  const _SlowMovingList({required this.items});

  final List<ReportSlowMovingItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Text('暂无滞销商品', style: AppTextStyles.bodySmall);
    }

    return Column(
      children: [
        for (final item in items) ...[
          _ReportInsightRow(
            title: item.name,
            value: item.lastSaleLabel,
            subtitle: item.detailLabel,
          ),
          if (item != items.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

final class _ReportInsightRow extends StatelessWidget {
  const _ReportInsightRow({
    required this.title,
    required this.value,
    required this.subtitle,
  });

  final String title;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

final class _SummaryMetrics extends StatelessWidget {
  const _SummaryMetrics({required this.metrics});

  final List<ReportSummaryMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth < 360 ? 2 : 3;

        return GridView.count(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          mainAxisExtent: 96,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: [
            for (final metric in metrics)
              RimsMetricCard(label: metric.label, value: metric.value),
          ],
        );
      },
    );
  }
}

final class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.viewModel});

  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final label in viewModel.periodLabels)
            Expanded(
              child: GestureDetector(
                onTap: () => unawaited(viewModel.selectPeriod(label)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: label == viewModel.selectedPeriodLabel
                        ? AppColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: label == viewModel.selectedPeriodLabel
                            ? AppColors.surface
                            : AppColors.textSecondary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _RankingList extends StatelessWidget {
  const _RankingList({required this.rankings});

  final List<ReportRanking> rankings;

  @override
  Widget build(BuildContext context) {
    final maxValue = rankings.isEmpty
        ? 0.0
        : rankings
              .map((ranking) => ranking.value)
              .reduce((a, b) => a > b ? a : b);

    return Column(
      children: [
        for (final ranking in rankings) ...[
          ReportRankingBar(ranking: ranking, maxValue: maxValue),
          if (ranking != rankings.last) const SizedBox(height: 14),
        ],
      ],
    );
  }
}

final class _InventoryOverview extends StatelessWidget {
  const _InventoryOverview({required this.buckets});

  final List<InventoryBucket> buckets;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ringChart = RimsRingChart(
          centerLabel: '库存\n概览',
          segments: [
            for (final bucket in buckets)
              RimsRingSegment(
                label: bucket.label,
                value: bucket.value,
                color: bucket.color,
              ),
          ],
        );
        final legend = _InventoryLegend(buckets: buckets);

        if (constraints.maxWidth < 330) {
          return Column(
            children: [ringChart, const SizedBox(height: 14), legend],
          );
        }

        return Row(
          children: [
            ringChart,
            const SizedBox(width: 18),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

final class _InventoryLegend extends StatelessWidget {
  const _InventoryLegend({required this.buckets});

  final List<InventoryBucket> buckets;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final bucket in buckets) ...[
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: bucket.color,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const SizedBox(width: 10, height: 10),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bucket.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                bucket.value.toStringAsFixed(0),
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (bucket != buckets.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}
