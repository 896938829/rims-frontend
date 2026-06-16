import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../view_models/documents_view_model.dart';

final class DocumentActionCard extends StatelessWidget {
  const DocumentActionCard({required this.action, super.key});

  final DocumentAction action;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Image.asset(action.iconPath, width: 24, height: 24),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyMedium.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
