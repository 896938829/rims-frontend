import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/outbox_operation.dart';
import '../view_models/sync_center_view_model.dart';

final class SyncCenterPage extends StatefulWidget {
  const SyncCenterPage({required this.viewModel, super.key});

  final SyncCenterViewModel viewModel;

  @override
  State<SyncCenterPage> createState() => _SyncCenterPageState();
}

final class _SyncCenterPageState extends State<SyncCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    widget.viewModel.load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('同步中心'),
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: '等待 ${widget.viewModel.waiting.length}'),
                Tab(text: '需处理 ${widget.viewModel.attention.length}'),
                Tab(text: '已完成 ${widget.viewModel.completed.length}'),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                _CommandBar(viewModel: widget.viewModel),
                if (widget.viewModel.commandFailure != null)
                  _FailureBand(
                    key: const ValueKey('sync-command-failure'),
                    message: widget.viewModel.commandFailure!.message,
                    onDismiss: widget.viewModel.dismissCommandFailure,
                  ),
                if (widget.viewModel.loadFailure != null)
                  _FailureBand(
                    key: const ValueKey('sync-load-failure'),
                    message: widget.viewModel.loadFailure!.message,
                  ),
                if (widget.viewModel.isBusy)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _OperationList(
                        operations: widget.viewModel.waiting,
                        viewModel: widget.viewModel,
                        onReview: _confirmAndSync,
                        onResolve: _resolveConflict,
                      ),
                      _OperationList(
                        operations: widget.viewModel.attention,
                        viewModel: widget.viewModel,
                        onReview: _confirmAndSync,
                        onResolve: _resolveConflict,
                      ),
                      _OperationList(
                        operations: widget.viewModel.completed,
                        viewModel: widget.viewModel,
                        onReview: _confirmAndSync,
                        onResolve: _resolveConflict,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmAndSync(OutboxOperation operation) async {
    final summary = widget.viewModel.confirmationSummary(operation.operationId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('复核并同步'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReviewFact(label: '仓库', value: summary.warehouse),
              _ReviewFact(label: '单据类型', value: summary.documentType),
              _ReviewFact(label: '明细行', value: '${summary.lineCount}'),
              const SizedBox(height: 8),
              const Text('过期假设', style: AppTextStyles.titleMedium),
              const SizedBox(height: 4),
              if (summary.staleAssumptions.isEmpty)
                const Text('无', style: AppTextStyles.bodySmall)
              else
                for (final assumption in summary.staleAssumptions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $assumption',
                      style: AppTextStyles.bodySmall,
                    ),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认同步'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.viewModel.reviewAndSync(operation.operationId);
    }
  }

  Future<void> _resolveConflict(OutboxOperation operation) async {
    final replacement = await showDialog<OutboxOperation>(
      context: context,
      builder: (context) => _ConflictResolutionDialog(operation: operation),
    );
    if (replacement != null) {
      await widget.viewModel.resolveConflict(
        operation.operationId,
        replacement,
      );
    }
  }
}

final class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.viewModel});

  final SyncCenterViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed:
                  viewModel.isBusy || viewModel.selectedOperationIds.isEmpty
                  ? null
                  : viewModel.retrySelected,
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('重试所选'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed:
                  viewModel.isBusy || viewModel.reviewedOperationIds.isEmpty
                  ? null
                  : viewModel.retryAllReviewed,
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('重试已复核'),
            ),
          ),
        ],
      ),
    );
  }
}

final class _FailureBand extends StatelessWidget {
  const _FailureBand({required this.message, this.onDismiss, super.key});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.error.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: AppTextStyles.bodySmall)),
            if (onDismiss != null)
              IconButton(
                tooltip: '关闭错误',
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

final class _OperationList extends StatelessWidget {
  const _OperationList({
    required this.operations,
    required this.viewModel,
    required this.onReview,
    required this.onResolve,
  });

  final List<OutboxOperation> operations;
  final SyncCenterViewModel viewModel;
  final ValueChanged<OutboxOperation> onReview;
  final ValueChanged<OutboxOperation> onResolve;

  @override
  Widget build(BuildContext context) {
    if (operations.isEmpty) {
      return const Center(child: Text('暂无记录', style: AppTextStyles.bodySmall));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      itemCount: operations.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final operation = operations[index];
        return _OperationRow(
          operation: operation,
          permissionBlocked: viewModel.isPermissionBlocked(
            operation.operationId,
          ),
          selected: viewModel.selectedOperationIds.contains(
            operation.operationId,
          ),
          reviewed: viewModel.reviewedOperationIds.contains(
            operation.operationId,
          ),
          busy: viewModel.isBusy,
          onSelected: (selected) =>
              viewModel.setSelected(operation.operationId, selected),
          onReview: () => onReview(operation),
          onCancel: () => viewModel.cancel(operation.operationId),
          onDiscard: () => viewModel.discard(operation.operationId),
          onResolve: () => onResolve(operation),
        );
      },
    );
  }
}

final class _OperationRow extends StatelessWidget {
  const _OperationRow({
    required this.operation,
    required this.permissionBlocked,
    required this.selected,
    required this.reviewed,
    required this.busy,
    required this.onSelected,
    required this.onReview,
    required this.onCancel,
    required this.onDiscard,
    required this.onResolve,
  });

  final OutboxOperation operation;
  final bool permissionBlocked;
  final bool selected;
  final bool reviewed;
  final bool busy;
  final ValueChanged<bool> onSelected;
  final VoidCallback onReview;
  final VoidCallback onCancel;
  final VoidCallback onDiscard;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final canCancel =
        operation.state == OutboxState.queued ||
        operation.state == OutboxState.retryableFailure;
    final canReview = canCancel && !permissionBlocked;
    final canSelect = canCancel && !permissionBlocked;
    final canDiscard =
        operation.state == OutboxState.succeeded ||
        operation.state == OutboxState.cancelled ||
        operation.state == OutboxState.permanentFailure ||
        operation.state == OutboxState.conflict;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: busy || !canSelect
                ? null
                : (value) => onSelected(value ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _kindLabel(operation.kind),
                        style: AppTextStyles.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _StateLabel(
                      state: operation.state,
                      permissionBlocked: permissionBlocked,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${operation.operationId} · 仓库 ${operation.warehouseId}',
                  style: AppTextStyles.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (canReview)
                      TextButton.icon(
                        onPressed: busy ? null : onReview,
                        icon: const Icon(Icons.fact_check_outlined, size: 17),
                        label: Text(reviewed ? '重新复核' : '复核并同步'),
                      ),
                    if (canCancel)
                      IconButton(
                        tooltip: '取消',
                        onPressed: busy ? null : onCancel,
                        icon: const Icon(Icons.cancel_outlined, size: 19),
                      ),
                    if (operation.state == OutboxState.conflict)
                      TextButton.icon(
                        onPressed: busy ? null : onResolve,
                        icon: const Icon(Icons.call_split, size: 17),
                        label: const Text('解决冲突'),
                      ),
                    if (canDiscard)
                      IconButton(
                        tooltip: '丢弃记录',
                        onPressed: busy ? null : onDiscard,
                        icon: const Icon(Icons.delete_outline, size: 19),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _StateLabel extends StatelessWidget {
  const _StateLabel({required this.state, this.permissionBlocked = false});

  final OutboxState state;
  final bool permissionBlocked;

  @override
  Widget build(BuildContext context) {
    final color = permissionBlocked
        ? AppColors.error
        : switch (state) {
            OutboxState.succeeded => AppColors.success,
            OutboxState.conflict ||
            OutboxState.permanentFailure => AppColors.error,
            OutboxState.syncing => AppColors.info,
            _ => AppColors.textSecondary,
          };
    return Text(
      permissionBlocked ? '权限受阻' : _stateLabel(state),
      style: AppTextStyles.bodySmall.copyWith(color: color),
    );
  }
}

final class _ReviewFact extends StatelessWidget {
  const _ReviewFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: AppTextStyles.bodySmall),
          ),
          Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
        ],
      ),
    );
  }
}

final class _ConflictResolutionDialog extends StatefulWidget {
  const _ConflictResolutionDialog({required this.operation});

  final OutboxOperation operation;

  @override
  State<_ConflictResolutionDialog> createState() =>
      _ConflictResolutionDialogState();
}

final class _ConflictResolutionDialogState
    extends State<_ConflictResolutionDialog> {
  late final TextEditingController _operationId;
  late final TextEditingController _key;
  late final TextEditingController _payload;
  String? _error;

  @override
  void initState() {
    super.initState();
    _operationId = TextEditingController();
    _key = TextEditingController();
    _payload = TextEditingController(
      text: jsonEncode(widget.operation.payload),
    );
  }

  @override
  void dispose() {
    _operationId.dispose();
    _key.dispose();
    _payload.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('解决冲突'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _operationId,
              decoration: const InputDecoration(labelText: '新 operation ID'),
            ),
            TextField(
              controller: _key,
              decoration: const InputDecoration(labelText: '新 idempotency key'),
            ),
            TextField(
              controller: _payload,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'replacement payload (JSON)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建替代操作')),
      ],
    );
  }

  void _submit() {
    try {
      final decoded = jsonDecode(_payload.text);
      if (_operationId.text.trim().isEmpty ||
          _key.text.trim().isEmpty ||
          decoded is! Map) {
        throw const FormatException();
      }
      Navigator.pop(
        context,
        OutboxOperation(
          operationId: _operationId.text.trim(),
          idempotencyKey: _key.text.trim(),
          accountId: widget.operation.accountId,
          warehouseId: widget.operation.warehouseId,
          kind: widget.operation.kind,
          payload: decoded.cast<String, Object?>(),
          state: OutboxState.queued,
          createdAt: DateTime.now().toUtc(),
          confirmedAt: DateTime.now().toUtc(),
        ),
      );
    } on FormatException {
      setState(() => _error = '请填写新 ID、新 key 和有效 JSON 对象');
    }
  }
}

String _kindLabel(OutboxOperationKind kind) => switch (kind) {
  OutboxOperationKind.documentReference => '单据引用',
  OutboxOperationKind.attachmentUpload => '附件上传',
  OutboxOperationKind.documentCreate => '创建单据',
  OutboxOperationKind.documentComplete => '完成单据',
  OutboxOperationKind.stocktakeConfirm => '确认盘点',
  OutboxOperationKind.stocktakeSettle => '结算盘点',
};

String _stateLabel(OutboxState state) => switch (state) {
  OutboxState.queued => '等待',
  OutboxState.syncing => '同步中',
  OutboxState.succeeded => '已完成',
  OutboxState.retryableFailure => '可重试',
  OutboxState.conflict => '冲突',
  OutboxState.permanentFailure => '已拒绝',
  OutboxState.cancelled => '已取消',
};
