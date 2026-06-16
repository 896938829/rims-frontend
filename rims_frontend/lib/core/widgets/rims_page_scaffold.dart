import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

final class RimsPageScaffold extends StatelessWidget {
  const RimsPageScaffold({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
