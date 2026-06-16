import 'package:flutter/material.dart';

import '../../../../core/widgets/rims_status_chip.dart';

final class ApiGuardChipGroup extends StatelessWidget {
  const ApiGuardChipGroup({
    required this.guards,
    this.kind = RimsStatusKind.info,
    super.key,
  });

  final List<String> guards;
  final RimsStatusKind kind;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final guard in guards) RimsStatusChip(label: guard, kind: kind),
      ],
    );
  }
}
