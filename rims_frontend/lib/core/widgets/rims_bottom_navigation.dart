import 'package:flutter/material.dart';

import '../navigation/app_tab.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

final class RimsBottomNavigation extends StatelessWidget {
  const RimsBottomNavigation({
    required this.currentTab,
    required this.onTabSelected,
    super.key,
  });

  final AppTab currentTab;
  final ValueChanged<AppTab> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: AppTab.values.map((tab) {
              final isSelected = tab == currentTab;

              return Expanded(
                child: Semantics(
                  key: Key('bottom-nav-${tab.name}'),
                  label: tab.label,
                  button: true,
                  selected: isSelected,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onTabSelected(tab),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            isSelected ? tab.activeIcon : tab.inactiveIcon,
                            width: 24,
                            height: 24,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tab.label,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: isSelected
                                  ? AppColors.primary
                                  : AppColors.textSecondary,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
