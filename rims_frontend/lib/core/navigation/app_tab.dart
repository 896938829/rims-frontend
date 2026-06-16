import '../resources/app_icons.dart';

enum AppTab {
  home(
    label: '首页',
    activeIcon: AppIcons.navHomeActive,
    inactiveIcon: AppIcons.navHomeInactive,
  ),
  inventory(
    label: '库存',
    activeIcon: AppIcons.navInventoryActive,
    inactiveIcon: AppIcons.navInventoryInactive,
  ),
  documents(
    label: '单据',
    activeIcon: AppIcons.navDocumentsActive,
    inactiveIcon: AppIcons.navDocumentsInactive,
  ),
  reports(
    label: '报表',
    activeIcon: AppIcons.navReportsActive,
    inactiveIcon: AppIcons.navReportsInactive,
  ),
  profile(
    label: '我的',
    activeIcon: AppIcons.navProfileActive,
    inactiveIcon: AppIcons.navProfileInactive,
  );

  const AppTab({
    required this.label,
    required this.activeIcon,
    required this.inactiveIcon,
  });

  final String label;
  final String activeIcon;
  final String inactiveIcon;
}
