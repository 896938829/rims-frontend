import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

enum RimsStatusKind { success, warning, error, info, pending }

final class RimsStatusChip extends StatelessWidget {
  const RimsStatusChip({
    required this.label,
    required this.kind,
    super.key,
  });

  final String label;
  final RimsStatusKind kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      RimsStatusKind.success => AppColors.success,
      RimsStatusKind.warning => AppColors.warning,
      RimsStatusKind.error => AppColors.error,
      RimsStatusKind.info => AppColors.info,
      RimsStatusKind.pending => AppColors.textSecondary,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: AppTextStyles.bodySmall.copyWith(color: color),
        ),
      ),
    );
  }
}
