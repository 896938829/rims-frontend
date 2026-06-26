import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/resources/app_icons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../view_models/inventory_view_model.dart';
import '../widgets/inventory_product_tile.dart';

final class InventoryPage extends StatefulWidget {
  const InventoryPage({
    this.viewModel,
    this.repository,
    this.warehouseName = '未选择仓库',
    super.key,
  });

  final InventoryViewModel? viewModel;
  final InventoryRepository? repository;
  final String warehouseName;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

final class _InventoryPageState extends State<InventoryPage> {
  late final InventoryViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        InventoryViewModel(
          repository: widget.repository,
          warehouseName: widget.warehouseName,
        );

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
        final visibleItems = viewModel.visibleItems;

        return RimsPageScaffold(
          key: const Key('tab-body-inventory'),
          child: ListView(
            children: [
              _InventoryHeader(warehouseName: viewModel.warehouseName),
              const SizedBox(height: 14),
              _InventorySearchBar(
                onChanged: (value) => unawaited(viewModel.updateQuery(value)),
              ),
              const SizedBox(height: 14),
              _InventoryTabs(
                tabs: viewModel.tabs,
                selectedTab: viewModel.selectedTab,
                onSelected: viewModel.selectTab,
              ),
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
                    if (metric != viewModel.metrics.last)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '商品库存'),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.items.isEmpty)
                RimsCard(
                  child: Text(
                    '正在加载库存...',
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
              else if (visibleItems.isEmpty)
                RimsCard(
                  child: Text(
                    '没有匹配的库存商品',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else
                for (final item in visibleItems) ...[
                  InventoryProductTile(product: item),
                  if (item != visibleItems.last) const SizedBox(height: 10),
                ],
            ],
          ),
        );
      },
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
  const _InventorySearchBar({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: RimsCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Image.asset(AppIcons.actionSearch, width: 20, height: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('inventory-search-field'),
                    onChanged: onChanged,
                    style: AppTextStyles.bodyMedium,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '搜索商品 / 条码 / 编码',
                      isDense: true,
                    ),
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
  const _InventoryTabs({
    required this.tabs,
    required this.selectedTab,
    required this.onSelected,
  });

  final List<String> tabs;
  final String selectedTab;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onSelected(tab),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tab == selectedTab
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
                        color: tab == selectedTab
                            ? AppColors.surface
                            : AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
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
