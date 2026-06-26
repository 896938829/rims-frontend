import 'package:flutter/material.dart';

import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_quick_action_button.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../view_models/home_view_model.dart';
import '../widgets/home_hero_card.dart';
import '../widgets/inventory_warning_card.dart';
import '../widgets/recent_document_tile.dart';

final class HomePage extends StatelessWidget {
  const HomePage({this.user, this.warehouse, this.viewModel, super.key});

  final AppUser? user;
  final Warehouse? warehouse;
  final HomeViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final effectiveViewModel =
        viewModel ?? HomeViewModel(user: user, warehouse: warehouse);

    return RimsPageScaffold(
      child: ListView(
        children: [
          HomeHeroCard(
            warehouseName: effectiveViewModel.warehouseName,
            greeting: effectiveViewModel.greeting,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final metric in effectiveViewModel.metrics) ...[
                Expanded(
                  child: RimsMetricCard(
                    label: metric.label,
                    value: metric.value,
                    delta: metric.delta,
                  ),
                ),
                if (metric != effectiveViewModel.metrics.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 4,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: 92,
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            children: [
              for (final action in effectiveViewModel.quickActions)
                RimsQuickActionButton(
                  label: action.label,
                  iconPath: action.icon,
                ),
            ],
          ),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '库存预警'),
          const SizedBox(height: 10),
          InventoryWarningCard(warnings: effectiveViewModel.warnings),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '最近单据'),
          const SizedBox(height: 10),
          for (final document in effectiveViewModel.recentDocuments) ...[
            RecentDocumentTile(document: document),
            if (document != effectiveViewModel.recentDocuments.last)
              const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
