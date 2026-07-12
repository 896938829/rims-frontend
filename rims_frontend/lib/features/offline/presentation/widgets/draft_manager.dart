import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/document_draft.dart';
import '../view_models/drafts_view_model.dart';

final class DraftManager extends StatefulWidget {
  const DraftManager({
    required this.viewModel,
    required this.onOpen,
    required this.warehouseName,
    super.key,
  });

  final DraftsViewModel viewModel;
  final ValueChanged<DocumentDraft> onOpen;
  final String Function(int warehouseId) warehouseName;

  @override
  State<DraftManager> createState() => _DraftManagerState();
}

final class _DraftManagerState extends State<DraftManager> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.viewModel.load());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        if (viewModel.isLoading && viewModel.drafts.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (viewModel.errorMessage case final error?) {
          return Center(
            child: Text(
              error,
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          );
        }
        if (viewModel.drafts.isEmpty) {
          return const Center(
            child: Text('暂无草稿', style: AppTextStyles.bodyMedium),
          );
        }

        return RefreshIndicator(
          onRefresh: viewModel.load,
          child: ListView.separated(
            key: const Key('draft-manager-list'),
            itemCount: viewModel.drafts.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = viewModel.drafts[index];
              return _DraftRow(
                item: item,
                warehouseName: widget.warehouseName(item.draft.warehouseId),
                onOpen: () => widget.onOpen(item.draft),
                onDuplicate: () =>
                    unawaited(viewModel.duplicate(item.draft.id)),
                onDiscard: () => _confirmDiscard(item.draft.id),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmDiscard(String draftId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('丢弃草稿'),
        content: const Text('确认丢弃此草稿？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('丢弃'),
          ),
        ],
      ),
    );
    await widget.viewModel.discard(draftId, confirmed: confirmed == true);
  }
}

final class _DraftRow extends StatelessWidget {
  const _DraftRow({
    required this.item,
    required this.warehouseName,
    required this.onOpen,
    required this.onDuplicate,
    required this.onDiscard,
  });

  final DraftListItem item;
  final String warehouseName;
  final VoidCallback onOpen;
  final VoidCallback onDuplicate;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Row(
        children: [
          Expanded(
            child: Text(
              _documentTypeLabel(item.draft.docType),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyMedium,
            ),
          ),
          if (item.requiresReview)
            const RimsStatusChip(label: '需复核', kind: RimsStatusKind.warning),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '$warehouseName · ${item.lineCount} 行 · ${DateFormat('MM-dd HH:mm').format(item.draft.updatedAt.toLocal())}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.bodySmall,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '打开',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new, size: 20),
          ),
          IconButton(
            tooltip: '复制',
            onPressed: onDuplicate,
            icon: const Icon(Icons.content_copy, size: 20),
          ),
          IconButton(
            tooltip: '丢弃',
            onPressed: onDiscard,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

String _documentTypeLabel(int docType) => switch (docType) {
  1 => '采购入库',
  2 => '销售出库',
  3 => '退货入库',
  4 => '调拨单',
  5 => '盘点单',
  6 => '转标准',
  _ => '未知单据',
};
