import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_mini_charts.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../view_models/reports_view_model.dart';
import '../widgets/report_ranking_bar.dart';

final class ReportsPage extends StatelessWidget {
  const ReportsPage({this.viewModel = const ReportsViewModel(), super.key});

  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsPageScaffold(
      key: const Key('tab-body-reports'),
      child: ListView(
        children: [
          Text('报表', style: AppTextStyles.headingLarge),
          const SizedBox(height: 4),
          Text(viewModel.dateRangeLabel, style: AppTextStyles.bodySmall),
          const SizedBox(height: 18),
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
            child: _InventoryOverview(buckets: viewModel.inventoryBuckets),
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
                '${bucket.value.toStringAsFixed(0)}%',
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
