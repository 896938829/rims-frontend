import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../view_models/profile_view_model.dart';

final class PermissionGroupCard extends StatelessWidget {
  const PermissionGroupCard({required this.group, super.key});

  final PermissionGroup group;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const SizedBox(
                  width: 34,
                  height: 34,
                  child: Icon(
                    Icons.admin_panel_settings_outlined,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  group.roleName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            group.summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final capability in group.capabilities)
                RimsStatusChip(
                  label: capability,
                  kind: group.roleName == '管理员'
                      ? RimsStatusKind.success
                      : RimsStatusKind.pending,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
