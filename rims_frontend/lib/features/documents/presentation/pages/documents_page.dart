import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/document_data.dart';
import '../../domain/repositories/documents_repository.dart';
import '../view_models/documents_view_model.dart';
import '../widgets/document_action_card.dart';
import '../widgets/document_flow_strip.dart';

final class DocumentsPage extends StatefulWidget {
  const DocumentsPage({this.viewModel, this.repository, super.key});

  final DocumentsViewModel? viewModel;
  final DocumentsRepository? repository;

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

final class _DocumentsPageState extends State<DocumentsPage> {
  late final DocumentsViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ?? DocumentsViewModel(repository: widget.repository);

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
                    DocumentActionCard(
                      action: action,
                      isSelected: action == viewModel.selectedAction,
                      onTap: () => viewModel.selectAction(action),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _DocumentForm(viewModel: viewModel),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '单据流程'),
              const SizedBox(height: 10),
              DocumentFlowStrip(steps: viewModel.flowSteps),
              const SizedBox(height: 20),
              const RimsSectionHeader(title: '最近单据'),
              const SizedBox(height: 10),
              if (viewModel.isLoading && viewModel.recentDocuments.isEmpty)
                RimsCard(
                  child: Text(
                    '正在加载单据...',
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
              else if (viewModel.recentDocuments.isEmpty)
                RimsCard(
                  child: Text(
                    '暂无最近单据',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall,
                  ),
                )
              else
                for (final document in viewModel.recentDocuments) ...[
                  _RecentDocumentCard(document: document),
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

final class _DocumentForm extends StatelessWidget {
  const _DocumentForm({required this.viewModel});

  final DocumentsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '新建 ${viewModel.selectedAction.label}',
                  style: AppTextStyles.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('document-product-field'),
            onChanged: viewModel.updateProductName,
            decoration: const InputDecoration(
              labelText: '商品',
              hintText: '例如：矿泉水 550ml',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('document-quantity-field'),
            keyboardType: TextInputType.number,
            onChanged: viewModel.updateQuantity,
            decoration: const InputDecoration(
              labelText: '数量',
              hintText: '例如：3',
              isDense: true,
            ),
          ),
          if (viewModel.formError != null) ...[
            const SizedBox(height: 10),
            Text(
              viewModel.formError!,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('document-create-button'),
            onPressed: viewModel.isSubmitting
                ? null
                : () => unawaited(viewModel.createDocument()),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(viewModel.isSubmitting ? '创建中...' : '创建单据'),
          ),
        ],
      ),
    );
  }
}

final class _RecentDocumentCard extends StatelessWidget {
  const _RecentDocumentCard({required this.document});

  final DocumentRecord document;

  @override
  Widget build(BuildContext context) {
    final detailText = document.productName.isEmpty
        ? document.number
        : '${document.number} · ${document.productName} x${document.quantity}';

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
                  detailText,
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
