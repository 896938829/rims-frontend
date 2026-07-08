import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/presentation/widgets/document_status_kind.dart';

final class RecentDocumentTile extends StatelessWidget {
  const RecentDocumentTile({required this.document, super.key});

  final DocumentRecord document;

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
              child: Icon(Icons.description_outlined, color: AppColors.primary),
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
                  style: AppTextStyles.bodyMedium,
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
          RimsStatusChip(
            label: document.status,
            kind: documentStatusKind(document.status),
          ),
        ],
      ),
    );
  }
}
