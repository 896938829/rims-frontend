import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../view_models/reports_view_model.dart';

final class ReportRankingBar extends StatelessWidget {
  const ReportRankingBar({
    required this.ranking,
    required this.maxValue,
    super.key,
  });

  final ReportRanking ranking;
  final double maxValue;

  @override
  Widget build(BuildContext context) {
    final progress = maxValue <= 0 || !maxValue.isFinite
        ? 0.0
        : (ranking.value / maxValue).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                ranking.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              ranking.amountLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: ColoredBox(
            color: AppColors.primaryLight,
            child: SizedBox(
              height: 8,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress,
                  child: const ColoredBox(color: AppColors.primary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
