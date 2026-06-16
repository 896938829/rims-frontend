import 'package:flutter/material.dart';

import '../theme/app_text_styles.dart';

final class RimsSectionHeader extends StatelessWidget {
  const RimsSectionHeader({
    required this.title,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppTextStyles.titleMedium)),
        ?trailing,
      ],
    );
  }
}
