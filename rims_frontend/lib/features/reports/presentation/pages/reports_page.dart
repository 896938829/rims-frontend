import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_mini_charts.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../domain/repositories/reports_repository.dart';
import '../view_models/reports_view_model.dart';
import '../widgets/report_ranking_bar.dart';

final class ReportsPage extends StatefulWidget {
  const ReportsPage({this.viewModel, this.repository, super.key});

  final ReportsViewModel? viewModel;
  final ReportsRepository? repository;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

final class _ReportsPageState extends State<ReportsPage> {
  late final ReportsViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ?? ReportsViewModel(repository: widget.repository);

    if (_ownsViewModel) {
      unawaited(viewModel.load());
    }
  }

  @override
  void dispose() {
    if (_ownsViewModel) {
      viewModel.dispose();
    }

    super.dispose();
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
              const SizedBox(height: 12),
              _PeriodSelector(viewModel: viewModel),
              const SizedBox(height: 18),
              if (viewModel.isLoading && viewModel.isEmpty)
                RimsCard(
                  child: Text(
                    '正在加载报表...',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else if (viewModel.errorMessage != null)
                RimsCard(
                  child: Text(
                    viewModel.errorMessage!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
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
                const RimsSectionHeader(title: '销售趋势（元）'),
                const SizedBox(height: 10),
                RimsCard(child: RimsLineChart(values: viewModel.trendPoints)),
                const SizedBox(height: 20),
                const RimsSectionHeader(title: '商品排行（销售额）'),
                const SizedBox(height: 10),
                RimsCard(child: _RankingList(rankings: viewModel.rankings)),
                const SizedBox(height: 20),
                const RimsSectionHeader(title: '库存概览'),
                const SizedBox(height: 10),
                RimsCard(
                  child: _InventoryOverview(
                    buckets: viewModel.inventoryBuckets,
                  ),
                ),
              ],
            ],
          ),
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
