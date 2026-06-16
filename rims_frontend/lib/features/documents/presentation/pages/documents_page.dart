import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../view_models/documents_view_model.dart';
import '../widgets/document_action_card.dart';
import '../widgets/document_flow_strip.dart';

final class DocumentsPage extends StatelessWidget {
  const DocumentsPage({this.viewModel = const DocumentsViewModel(), super.key});

  final DocumentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsPageScaffold(
      key: const Key('tab-body-documents'),
      child: ListView(
        children: [
          Text('单据', style: AppTextStyles.headingLarge),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 72,
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            children: [
              for (final action in viewModel.actions)
                DocumentActionCard(action: action),
            ],
          ),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '单据流程'),
          const SizedBox(height: 10),
          DocumentFlowStrip(steps: viewModel.flowSteps),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '最近单据'),
          const SizedBox(height: 10),
          for (final document in viewModel.recentDocuments) ...[
            _RecentDocumentCard(document: document),
            if (document != viewModel.recentDocuments.last)
              const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

final class _RecentDocumentCard extends StatelessWidget {
  const _RecentDocumentCard({required this.document});

  final RecentDocument document;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.article_outlined, color: AppColors.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  document.number,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          RimsStatusChip(label: document.status, kind: _statusKind),
        ],
      ),
    );
  }

  RimsStatusKind get _statusKind {
    return switch (document.status) {
      '已完成' => RimsStatusKind.success,
      '待提交' => RimsStatusKind.warning,
      '已取消' => RimsStatusKind.error,
      _ => RimsStatusKind.info,
    };
  }
}
