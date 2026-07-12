import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/services/attachment_picker.dart';
import '../view_models/attachments_view_model.dart';
import 'attachment_preview.dart';

final class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({
    required this.viewModel,
    this.autoLoad = true,
    this.maximumCount = 9,
    super.key,
  });

  final AttachmentsViewModel viewModel;
  final bool autoLoad;
  final int maximumCount;

  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

final class _AttachmentPanelState extends State<AttachmentPanel>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoLoad) {
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    await widget.viewModel.recoverInterrupted();
    await widget.viewModel.load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.viewModel.resume());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      widget.viewModel.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        final count = viewModel.attachments.length + viewModel.queue.length;
        final canAdd = count < widget.maximumCount && !viewModel.isBusy;
        return Column(
          key: const Key('attachment-panel'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '附件 ($count/${widget.maximumCount})',
                    style: AppTextStyles.titleMedium,
                  ),
                ),
                _SourceButton(
                  tooltip: '拍照',
                  icon: Icons.photo_camera_outlined,
                  onPressed: canAdd
                      ? () => unawaited(
                          viewModel.pickAndUpload(AttachmentPickSource.camera),
                        )
                      : null,
                ),
                _SourceButton(
                  tooltip: '从相册选择',
                  icon: Icons.photo_library_outlined,
                  onPressed: canAdd
                      ? () => unawaited(
                          viewModel.pickAndUpload(AttachmentPickSource.gallery),
                        )
                      : null,
                ),
                _SourceButton(
                  tooltip: '选择文件',
                  icon: Icons.attach_file,
                  onPressed: canAdd
                      ? () => unawaited(
                          viewModel.pickAndUpload(AttachmentPickSource.file),
                        )
                      : null,
                ),
              ],
            ),
            if (viewModel.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(
                viewModel.errorMessage!,
                key: const Key('attachment-error'),
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
              ),
            ],
            const SizedBox(height: 8),
            if (viewModel.isLoading && viewModel.attachments.isEmpty)
              const SizedBox(
                height: 72,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (count == 0)
              SizedBox(
                height: 72,
                child: Center(
                  child: Text('暂无附件', style: AppTextStyles.bodySmall),
                ),
              )
            else ...[
              for (final item in viewModel.queue) ...[
                _TransferRow(item: item, viewModel: viewModel),
                const SizedBox(height: 8),
              ],
              for (
                var index = 0;
                index < viewModel.attachments.length;
                index++
              ) ...[
                _AttachmentRow(
                  attachment: viewModel.attachments[index],
                  index: index,
                  total: viewModel.attachments.length,
                  viewModel: viewModel,
                ),
                if (index != viewModel.attachments.length - 1)
                  const SizedBox(height: 8),
              ],
            ],
          ],
        );
      },
    );
  }
}

final class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
    );
  }
}

final class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.item, required this.viewModel});

  final AttachmentQueueItem item;
  final AttachmentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final progress = item.total <= 0 ? 0.0 : item.sent / item.total;
    final retryable =
        item.state == AttachmentTransferState.failed ||
        item.state == AttachmentTransferState.interrupted ||
        item.state == AttachmentTransferState.cancelled;
    return _RowFrame(
      key: Key('attachment-transfer-${item.requestId}'),
      child: Row(
        children: [
          AttachmentPreview(
            mimeType: item.staged.pending.mimeType,
            localPath: item.staged.thumbnailPath,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  item.staged.pending.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: retryable ? 0 : progress.clamp(0, 1),
                ),
              ],
            ),
          ),
          if (retryable)
            IconButton(
              tooltip: '重试上传',
              onPressed: () => unawaited(viewModel.retry(item.requestId)),
              icon: const Icon(Icons.refresh),
            )
          else
            IconButton(
              tooltip: '取消上传',
              onPressed: () => viewModel.cancel(item.requestId),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

final class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.attachment,
    required this.index,
    required this.total,
    required this.viewModel,
  });

  final Attachment attachment;
  final int index;
  final int total;
  final AttachmentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return _RowFrame(
      key: Key('attachment-${attachment.id}'),
      child: Row(
        children: [
          AttachmentPreview(
            mimeType: attachment.mimeType,
            localPath: viewModel.downloadedPathFor(attachment.id),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium,
                ),
                Text(
                  _formatBytes(attachment.fileSize),
                  style: AppTextStyles.bodySmall,
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '附件操作',
            onSelected: (action) => _runAction(context, action),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'share', child: Text('下载并分享')),
              const PopupMenuItem(value: 'replace', child: Text('替换')),
              if (index > 0)
                const PopupMenuItem(value: 'up', child: Text('上移')),
              if (index < total - 1)
                const PopupMenuItem(value: 'down', child: Text('下移')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(BuildContext context, String action) async {
    switch (action) {
      case 'share':
        await viewModel.downloadAndShare(attachment);
      case 'replace':
        await viewModel.replace(attachment, AttachmentPickSource.gallery);
      case 'up':
        await _move(-1);
      case 'down':
        await _move(1);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除附件'),
            content: Text('确认删除 ${attachment.originalName}？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true) await viewModel.delete(attachment);
    }
  }

  Future<void> _move(int offset) async {
    final ids = viewModel.attachments.map((item) => item.id).toList();
    final target = index + offset;
    final moving = ids.removeAt(index);
    ids.insert(target, moving);
    await viewModel.reorder(ids);
  }
}

final class _RowFrame extends StatelessWidget {
  const _RowFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
