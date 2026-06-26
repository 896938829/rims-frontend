import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_quick_action_button.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../view_models/home_view_model.dart';
import '../widgets/home_hero_card.dart';
import '../widgets/inventory_warning_card.dart';
import '../widgets/recent_document_tile.dart';

final class HomePage extends StatefulWidget {
  const HomePage({
    this.user,
    this.warehouse,
    this.viewModel,
    this.inventoryRepository,
    this.documentsRepository,
    super.key,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final HomeViewModel? viewModel;
  final InventoryRepository? inventoryRepository;
  final DocumentsRepository? documentsRepository;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  late final HomeViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        HomeViewModel(
          user: widget.user,
          warehouse: widget.warehouse,
          inventoryRepository: widget.inventoryRepository,
          documentsRepository: widget.documentsRepository,
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
        return RimsPageScaffold(
          child: ListView(
            children: [
              HomeHeroCard(
                warehouseName: viewModel.warehouseName,
                greeting: viewModel.greeting,
              ),
              const SizedBox(height: 14),
              if (viewModel.errorMessage != null) ...[
                RimsCard(
                  child: Text(
                    viewModel.errorMessage!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Row(
                children: [
                  for (final metric in viewModel.metrics) ...[
                    Expanded(
                      child: RimsMetricCard(
                        label: metric.label,
                        value: metric.value,
                        delta: metric.delta,
                      ),
                    ),
                    if (metric != viewModel.metrics.last)
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
                  for (final action in viewModel.quickActions)
                    RimsQuickActionButton(
                      label: action.label,
                      iconPath: action.icon,
                    ),
                ],
              ),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '库存预警'),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.warnings.isEmpty)
                const _HomeStateCard(label: '正在加载库存预警...')
              else if (viewModel.warnings.isEmpty)
                const _HomeStateCard(label: '暂无库存预警')
              else
                InventoryWarningCard(warnings: viewModel.warnings),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '最近单据'),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.recentDocuments.isEmpty)
                const _HomeStateCard(label: '正在加载最近单据...')
              else if (viewModel.recentDocuments.isEmpty)
                const _HomeStateCard(label: '暂无最近单据')
              else
                for (final document in viewModel.recentDocuments) ...[
                  RecentDocumentTile(document: document),
                  if (document != viewModel.recentDocuments.last)
                    const SizedBox(height: 10),
                ],
            ],
          ),
        );
      },
    );
  }
}

final class _HomeStateCard extends StatelessWidget {
  const _HomeStateCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: AppTextStyles.bodySmall,
      ),
    );
  }
}
