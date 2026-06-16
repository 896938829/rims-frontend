import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../view_models/home_view_model.dart';

final class InventoryWarningCard extends StatelessWidget {
  const InventoryWarningCard({
    required this.warnings,
    super.key,
  });

  final List<InventoryWarning> warnings;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        children: [
          for (final warning in warnings) ...[
            _InventoryWarningRow(warning: warning),
            if (warning != warnings.last)
              const Divider(height: 18, color: AppColors.border),
          ],
        ],
      ),
    );
  }
}

final class _InventoryWarningRow extends StatelessWidget {
  const _InventoryWarningRow({required this.warning});

  final InventoryWarning warning;

  @override
  Widget build(BuildContext context) {
    final kind = switch (warning.level) {
      'warning' => RimsStatusKind.warning,
      'info' => RimsStatusKind.info,
      _ => RimsStatusKind.pending,
    };

    return Row(
      children: [
        Expanded(
          child: Text(warning.label, style: AppTextStyles.bodyMedium),
        ),
        Text(
          '${warning.count}',
          style: AppTextStyles.headingMedium.copyWith(
            color: kind == RimsStatusKind.warning
                ? AppColors.warning
                : AppColors.info,
          ),
        ),
        const SizedBox(width: 10),
        RimsStatusChip(label: _levelLabel, kind: kind),
      ],
    );
  }

  String get _levelLabel {
    return switch (warning.level) {
      'warning' => '需关注',
      'info' => '提醒',
      _ => '待处理',
    };
  }
}
