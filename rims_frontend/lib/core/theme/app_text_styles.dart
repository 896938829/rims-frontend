import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  static const TextStyle titleLarge = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.w700,
  );

  static const TextStyle bodyMedium = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle labelMedium = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );
}
