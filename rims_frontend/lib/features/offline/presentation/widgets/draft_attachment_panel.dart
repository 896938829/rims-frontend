import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../view_models/draft_attachments_view_model.dart';

final class DraftAttachmentPanel extends StatelessWidget {
  const DraftAttachmentPanel({required this.viewModel, super.key});

  final DraftAttachmentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '附件 (${viewModel.staged.length}/9)',
                  style: AppTextStyles.bodyMedium,
                ),
              ),
              _PickButton(
                key: const Key('document-draft-attachment-camera'),
                tooltip: '拍照暂存',
                icon: Icons.photo_camera_outlined,
                onPressed: viewModel.isBusy || !viewModel.isMutationAllowed
                    ? null
                    : () => unawaited(
                        viewModel.pick(AttachmentPickSource.camera),
                      ),
              ),
              _PickButton(
                key: const Key('document-draft-attachment-gallery'),
                tooltip: '相册暂存',
                icon: Icons.photo_library_outlined,
                onPressed: viewModel.isBusy || !viewModel.isMutationAllowed
                    ? null
                    : () => unawaited(
                        viewModel.pick(AttachmentPickSource.gallery),
                      ),
              ),
              _PickButton(
                key: const Key('document-draft-attachment-file'),
                tooltip: '文件暂存',
                icon: Icons.attach_file,
                onPressed: viewModel.isBusy || !viewModel.isMutationAllowed
                    ? null
                    : () =>
                          unawaited(viewModel.pick(AttachmentPickSource.file)),
              ),
            ],
          ),
          if (viewModel.errorMessage case final error?)
            Text(
              error,
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          for (final item in viewModel.staged)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                item.pending.originalName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '移除暂存附件',
                onPressed: viewModel.isMutationAllowed
                    ? () => unawaited(viewModel.remove(item.pending.requestId))
                    : null,
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

final class _PickButton extends StatelessWidget {
  const _PickButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 36,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
      ),
    );
  }
}
