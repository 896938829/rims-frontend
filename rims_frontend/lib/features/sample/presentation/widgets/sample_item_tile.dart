import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/sample_item.dart';

final class SampleItemTile extends StatelessWidget {
  const SampleItemTile({
    required this.item,
    super.key,
  });

  final SampleItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        item.title,
        style: AppTextStyles.bodyMedium,
      ),
      subtitle: Text(
        item.id,
        style: AppTextStyles.labelMedium,
      ),
    );
  }
}
