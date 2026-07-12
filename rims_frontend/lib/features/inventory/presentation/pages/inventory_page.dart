import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/resources/app_icons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_metric_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../domain/entities/inventory_item.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../view_models/inventory_view_model.dart';
import '../widgets/inventory_product_tile.dart';

final class InventoryPage extends StatefulWidget {
  const InventoryPage({
    this.viewModel,
    this.repository,
    this.documentsRepository,
    this.warehouseName = '未选择仓库',
    this.canManageInventorySettings = false,
    this.eventBus,
    this.onScanRequested,
    this.barcodeInputs,
    super.key,
  });

  final InventoryViewModel? viewModel;
  final InventoryRepository? repository;
  final DocumentsRepository? documentsRepository;
  final String warehouseName;
  final bool canManageInventorySettings;
  final AppEventBus? eventBus;
  final Future<InventoryItem?> Function(BuildContext context)? onScanRequested;
  final Stream<String>? barcodeInputs;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

final class _InventoryPageState extends State<InventoryPage> {
  late final InventoryViewModel viewModel;
  late final bool _ownsViewModel;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;
  StreamSubscription<String>? _barcodeSubscription;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        InventoryViewModel(
          repository: widget.repository,
          documentsRepository: widget.documentsRepository,
          warehouseName: widget.warehouseName,
          canManageInventorySettings: widget.canManageInventorySettings,
        );

    if (_ownsViewModel) {
      unawaited(viewModel.load());
    }
    _subscribeToRefreshEvents();
    _subscribeToBarcodeInputs();
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.eventBus != oldWidget.eventBus) {
      unawaited(_refreshSubscription?.cancel());
      _subscribeToRefreshEvents();
    }
    if (widget.barcodeInputs != oldWidget.barcodeInputs) {
      unawaited(_barcodeSubscription?.cancel());
      _subscribeToBarcodeInputs();
    }
  }

  @override
  void dispose() {
    unawaited(_refreshSubscription?.cancel());
    unawaited(_barcodeSubscription?.cancel());
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
        final visibleItems = viewModel.visibleItems;

        return RimsPageScaffold(
          key: const Key('tab-body-inventory'),
          child: ListView(
            children: [
              _InventoryHeader(warehouseName: viewModel.warehouseName),
              if (viewModel.cacheStatusLabel case final label?) ...[
                const SizedBox(height: 10),
                Semantics(
                  label: label,
                  child: Row(
                    key: const Key('inventory-cache-status'),
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
                ),
              ],
              const SizedBox(height: 14),
              _InventorySearchBar(
                onChanged: (value) => unawaited(viewModel.updateQuery(value)),
                onBarcodeLookup: () => unawaited(_openScannerOrLookup()),
              ),
              if (viewModel.barcodeLookupError != null) ...[
                const SizedBox(height: 10),
                RimsCard(
                  child: Text(
                    viewModel.barcodeLookupError!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ),
              ],
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
              else if (visibleItems.isEmpty) ...[
                RimsCard(
                  child: Text(
                    '没有匹配的库存商品',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                ),
                if (viewModel.items.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _InventoryPaginationControl(viewModel: viewModel),
                ],
              ] else ...[
                for (final item in visibleItems) ...[
                  InventoryProductTile(
                    key: ValueKey('inventory-item-${item.id}'),
                    product: item,
                    onTap: () {
                      viewModel.selectItem(item);
                      _showInventoryDetail(context, item);
                    },
                  ),
                  if (item != visibleItems.last) const SizedBox(height: 10),
                ],
                const SizedBox(height: 12),
                _InventoryPaginationControl(viewModel: viewModel),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _lookupBarcode() async {
    await _lookupBarcodeValue(viewModel.query);
  }

  Future<void> _lookupBarcodeValue(String barcode) async {
    final item = await viewModel.lookupBarcode(barcode);
    if (!mounted || item == null) {
      return;
    }

    _showInventoryDetail(context, item);
  }

  Future<void> _openScannerOrLookup() async {
    final launcher = widget.onScanRequested;
    if (launcher == null) {
      await _lookupBarcode();
      return;
    }
    final item = await launcher(context);
    if (!mounted || item == null) return;
    viewModel.selectItem(item);
    _showInventoryDetail(context, item);
  }

  void _subscribeToBarcodeInputs() {
    _barcodeSubscription = widget.barcodeInputs?.listen(
      (barcode) => unawaited(_lookupBarcodeValue(barcode)),
    );
  }

  void _showInventoryDetail(BuildContext context, InventoryItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _InventoryDetailSheet(viewModel: viewModel, initialItem: item),
    );
  }
}

final class _InventoryPaginationControl extends StatelessWidget {
  const _InventoryPaginationControl({required this.viewModel});

  final InventoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    if (viewModel.loadMoreFailure != null) {
      return Semantics(
        label: '重试加载更多库存',
        button: true,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('inventory-load-more-retry'),
            onPressed: viewModel.isLoadingMore
                ? null
                : () => unawaited(viewModel.retryLoadMore()),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('加载失败，重试'),
          ),
        ),
      );
    }

    if (viewModel.hasMore) {
      return Semantics(
        label: viewModel.isLoadingMore ? '正在加载更多库存' : '加载更多库存',
        button: true,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: TextButton.icon(
            key: const Key('inventory-load-more-button'),
            onPressed: viewModel.isLoadingMore
                ? null
                : () => unawaited(viewModel.loadMore()),
            icon: viewModel.isLoadingMore
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.keyboard_arrow_down, size: 20),
            label: Text(
              viewModel.isLoadingMore
                  ? '正在加载...'
                  : '加载更多 (${viewModel.loadedCount}/${viewModel.total})',
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: '库存已全部加载',
      child: SizedBox(
        key: const Key('inventory-page-end'),
        height: 48,
        width: double.infinity,
        child: Center(child: Text('已加载全部 ${viewModel.loadedCount} 条库存')),
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
  const _InventorySearchBar({
    required this.onChanged,
    required this.onBarcodeLookup,
  });

  final ValueChanged<String> onChanged;
  final VoidCallback onBarcodeLookup;

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
        Tooltip(
          message: '条码查询',
          child: GestureDetector(
            key: const Key('inventory-scan-button'),
            behavior: HitTestBehavior.opaque,
            onTap: onBarcodeLookup,
            child: RimsCard(
              padding: const EdgeInsets.all(11),
              child: Image.asset(AppIcons.actionScan, width: 20, height: 20),
            ),
          ),
        ),
      ],
    );
  }
}

final class _InventoryDetailSheet extends StatelessWidget {
  const _InventoryDetailSheet({
    required this.viewModel,
    required this.initialItem,
  });

  final InventoryViewModel viewModel;
  final InventoryItem initialItem;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        final item = viewModel.selectedItem ?? initialItem;

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 18,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('库存详情', style: AppTextStyles.headingLarge),
                const SizedBox(height: 12),
                Text(
                  item.productName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(item.sku, style: AppTextStyles.bodySmall),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _InventoryDetailMetric(
                        label: '可用库存',
                        value: item.availableQuantity,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InventoryDetailMetric(
                        label: '账面库存',
                        value: item.stockQuantity,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                RimsCard(
                  child: Column(
                    children: [
                      _InventoryDetailRow(
                        label: '库存状态',
                        value: item.statusLabel,
                      ),
                      const SizedBox(height: 10),
                      _InventoryDetailRow(
                        label: '预警阈值',
                        value: item.alertThreshold?.toString() ?? '未设置',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _InventoryTransactionsSection(item: item, viewModel: viewModel),
                if (viewModel.canManageInventorySettings) ...[
                  const SizedBox(height: 12),
                  if (item.id > 0)
                    _InventorySettingsForm(
                      key: ValueKey(
                        'inventory-settings-${item.id}-${item.alertThreshold}-${item.status}',
                      ),
                      item: item,
                      viewModel: viewModel,
                    )
                  else
                    RimsCard(
                      child: Text(
                        '该商品暂无库存记录',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _InventoryTransactionsSection extends StatelessWidget {
  const _InventoryTransactionsSection({
    required this.item,
    required this.viewModel,
  });

  final InventoryItem item;
  final InventoryViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final transactions = viewModel.transactionsFor(item);
    final visibleTransactions = transactions.take(5).toList(growable: false);

    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最近库存流水', style: AppTextStyles.titleMedium),
          const SizedBox(height: 10),
          if (viewModel.isLoadingTransactions && transactions.isEmpty)
            Text('正在加载流水...', style: AppTextStyles.bodySmall)
          else if (viewModel.transactionError != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  viewModel.transactionError!,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: viewModel.isLoadingTransactions
                      ? null
                      : () => unawaited(viewModel.loadTransactions()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试流水'),
                ),
              ],
            )
          else if (transactions.isEmpty)
            Text('暂无该商品最近流水', style: AppTextStyles.bodySmall)
          else
            for (final transaction in visibleTransactions) ...[
              _InventoryTransactionRow(transaction: transaction),
              if (transaction != visibleTransactions.last)
                const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

final class _InventoryTransactionRow extends StatelessWidget {
  const _InventoryTransactionRow({required this.transaction});

  final TransactionRecord transaction;

  @override
  Widget build(BuildContext context) {
    final color = switch (transaction.direction) {
      1 => AppColors.success,
      -1 => AppColors.warning,
      _ => AppColors.primary,
    };
    final icon = switch (transaction.direction) {
      1 => Icons.call_received,
      -1 => Icons.call_made,
      _ => Icons.swap_vert,
    };

    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, color: color, size: 18),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${transaction.docTypeName} · ${transaction.docNo}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${transaction.beforeQty} -> ${transaction.afterQty}',
                style: AppTextStyles.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              transaction.directionLabel,
              style: AppTextStyles.bodySmall.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'x${transaction.quantity}',
              style: AppTextStyles.bodySmall.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

final class _InventoryDetailRow extends StatelessWidget {
  const _InventoryDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: AppTextStyles.bodySmall),
        const Spacer(),
        Text(
          value,
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

final class _InventorySettingsForm extends StatefulWidget {
  const _InventorySettingsForm({
    required this.item,
    required this.viewModel,
    super.key,
  });

  final InventoryItem item;
  final InventoryViewModel viewModel;

  @override
  State<_InventorySettingsForm> createState() => _InventorySettingsFormState();
}

final class _InventorySettingsFormState extends State<_InventorySettingsForm> {
  late final TextEditingController _alertThresholdController;
  late int _status;

  @override
  void initState() {
    super.initState();
    _alertThresholdController = TextEditingController(
      text: widget.item.alertThreshold?.toString() ?? '',
    );
    _status = _statusValueFor(widget.item);
  }

  @override
  void dispose() {
    _alertThresholdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('库存设置', style: AppTextStyles.titleMedium),
          const SizedBox(height: 12),
          TextField(
            key: const Key('inventory-alert-threshold-field'),
            controller: _alertThresholdController,
            enabled: !widget.viewModel.isSavingSettings,
            keyboardType: TextInputType.number,
            style: AppTextStyles.bodyMedium,
            decoration: const InputDecoration(
              labelText: '预警阈值',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const Key('inventory-status-field'),
            initialValue: _status,
            decoration: const InputDecoration(
              labelText: '库存状态',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem<int>(value: 1, child: Text('启用')),
              DropdownMenuItem<int>(value: 0, child: Text('停用')),
              DropdownMenuItem<int>(value: 2, child: Text('预警')),
            ],
            onChanged: widget.viewModel.isSavingSettings
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _status = value);
                    }
                  },
          ),
          if (widget.viewModel.settingsError != null) ...[
            const SizedBox(height: 10),
            Text(
              widget.viewModel.settingsError!,
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('inventory-save-settings-button'),
              onPressed: widget.viewModel.isSavingSettings
                  ? null
                  : () => unawaited(_save(context)),
              child: Text(
                widget.viewModel.isSavingSettings ? '保存中...' : '保存设置',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final thresholdText = _alertThresholdController.text.trim();
    final alertThreshold = thresholdText.isEmpty
        ? null
        : int.tryParse(thresholdText);
    if (thresholdText.isNotEmpty && alertThreshold == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('预警阈值必须是数字')));
      return;
    }

    await widget.viewModel.updateSelectedItemSettings(
      alertThreshold: alertThreshold,
      status: _status,
    );
  }

  int _statusValueFor(InventoryItem item) {
    final status = item.status;
    if (status == 0 || status == 1 || status == 2) {
      return status!;
    }

    if (item.statusLabel == '停用') {
      return 0;
    }

    if (item.statusLabel == '低库存') {
      return 2;
    }

    return 1;
  }
}

final class _InventoryDetailMetric extends StatelessWidget {
  const _InventoryDetailMetric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.bodySmall),
          const SizedBox(height: 8),
          Text('$value', style: AppTextStyles.metric),
        ],
      ),
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
