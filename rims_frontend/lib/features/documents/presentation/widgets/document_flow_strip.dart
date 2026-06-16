import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';

final class DocumentFlowStrip extends StatelessWidget {
  const DocumentFlowStrip({required this.steps, super.key});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          for (var index = 0; index < steps.length; index++) ...[
            Expanded(
              child: _DocumentFlowStep(
                label: steps[index],
                stepNumber: index + 1,
              ),
            ),
            if (index != steps.length - 1) const _DocumentFlowDivider(),
          ],
        ],
      ),
    );
  }
}

final class _DocumentFlowStep extends StatelessWidget {
  const _DocumentFlowStep({required this.label, required this.stepNumber});

  final String label;
  final int stepNumber;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: 28,
            child: Center(
              child: Text(
                '$stepNumber',
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.surface,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySmall.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

final class _DocumentFlowDivider extends StatelessWidget {
  const _DocumentFlowDivider();

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(999),
          ),
          child: const SizedBox(height: 2),
        ),
      ),
    );
  }
}
