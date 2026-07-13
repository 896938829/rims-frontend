import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
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
import '../../../reports/domain/repositories/reports_repository.dart';
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
    this.reportsRepository,
    this.eventBus,
    this.onQuickActionSelected,
    this.onDataFreshnessChanged,
    super.key,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final HomeViewModel? viewModel;
  final InventoryRepository? inventoryRepository;
  final DocumentsRepository? documentsRepository;
  final ReportsRepository? reportsRepository;
  final AppEventBus? eventBus;
  final ValueChanged<HomeQuickAction>? onQuickActionSelected;
  final ValueChanged<HomeDataFreshness?>? onDataFreshnessChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  late final HomeViewModel viewModel;
  late final bool _ownsViewModel;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;

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
          reportsRepository: widget.reportsRepository,
        );

    if (_ownsViewModel) {
      unawaited(_load());
    }
    _subscribeToRefreshEvents();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
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
        .listen((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    final load = viewModel.load();
    final generation = viewModel.loadGeneration;
    await load;
    if (!mounted || generation != viewModel.loadGeneration) return;
    _reportDataFreshness();
  }

  void _reportDataFreshness() {
    widget.onDataFreshnessChanged?.call(viewModel.dataFreshness);
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
                            : () => unawaited(_load()),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
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
                      onPressed: widget.onQuickActionSelected == null
                          ? null
                          : () => widget.onQuickActionSelected!(action),
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
              RimsSectionHeader(
                title: '最近单据',
                trailing: viewModel.recentDocuments.isEmpty
                    ? null
                    : Text(
                        '已显示 ${viewModel.recentDocuments.length} / ${viewModel.recentDocumentsTotal}',
                        key: const Key('home-recent-documents-coverage'),
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
              ),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.recentDocuments.isEmpty)
                const _HomeStateCard(label: '正在加载最近单据...')
              else if (viewModel.recentDocumentsErrorMessage != null)
                _HomeRetryCard(
                  message: viewModel.recentDocumentsErrorMessage!,
                  isLoading: viewModel.isLoading,
                  onRetry: () => unawaited(_load()),
                )
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

final class _HomeRetryCard extends StatelessWidget {
  const _HomeRetryCard({
    required this.message,
    required this.isLoading,
    required this.onRetry,
  });

  final String message;
  final bool isLoading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: isLoading ? null : onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
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
