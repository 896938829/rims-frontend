import 'package:flutter/material.dart';

import '../../../../core/resources/app_icons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../view_models/inventory_view_model.dart';
import '../widgets/inventory_product_tile.dart';

final class InventoryPage extends StatelessWidget {
  const InventoryPage({this.viewModel = const InventoryViewModel(), super.key});

  final InventoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsPageScaffold(
      key: const Key('tab-body-inventory'),
      child: ListView(
        children: [
          _InventoryHeader(warehouseName: viewModel.warehouseName),
          const SizedBox(height: 14),
          const _InventorySearchBar(),
          const SizedBox(height: 14),
          _InventoryTabs(tabs: viewModel.tabs),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final metric in viewModel.metrics) ...[
                Expanded(
                  child: RimsMetricCard(
                    label: metric.label,
                    value: metric.value,
                  ),
                ),
                if (metric != viewModel.metrics.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '商品库存'),
          const SizedBox(height: 10),
          for (final product in viewModel.products) ...[
            InventoryProductTile(product: product),
            if (product != viewModel.products.last) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

final class _InventoryHeader extends StatelessWidget {
  const _InventoryHeader({required this.warehouseName});

  final String warehouseName;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(warehouseName, style: AppTextStyles.headingLarge),
              const SizedBox(height: 4),
              Text('库存看板', style: AppTextStyles.bodySmall),
            ],
          ),
        ),
        Image.asset(AppIcons.moduleWarehouse, width: 38, height: 38),
      ],
    );
  }
}

final class _InventorySearchBar extends StatelessWidget {
  const _InventorySearchBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: RimsCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Image.asset(AppIcons.actionSearch, width: 20, height: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索商品 / 条码 / 编码',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        RimsCard(
          padding: const EdgeInsets.all(11),
          child: Image.asset(AppIcons.actionFilter, width: 20, height: 20),
        ),
      ],
    );
  }
}

final class _InventoryTabs extends StatelessWidget {
  const _InventoryTabs({required this.tabs});

  final List<String> tabs;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tab == tabs.first
                      ? AppColors.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Text(
                    tab,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodyMedium.copyWith(
                      color: tab == tabs.first
                          ? AppColors.surface
                          : AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
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
