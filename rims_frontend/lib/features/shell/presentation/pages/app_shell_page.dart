import 'package:flutter/material.dart';

import '../../../../core/widgets/rims_bottom_navigation.dart';
import '../../../home/presentation/pages/home_page.dart';
import '../../../inventory/presentation/pages/inventory_page.dart';
import '../view_models/app_tab.dart';

final class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key});

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

final class _AppShellPageState extends State<AppShellPage> {
  AppTab _currentTab = AppTab.home;

  static const Map<AppTab, Widget> _tabBodies = {
    AppTab.home: HomePage(),
    AppTab.inventory: InventoryPage(),
    AppTab.documents: Center(key: Key('tab-body-documents'), child: Text('单据')),
    AppTab.reports: Center(key: Key('tab-body-reports'), child: Text('报表')),
    AppTab.profile: Center(key: Key('tab-body-profile'), child: Text('我的')),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabBodies[_currentTab]!,
      bottomNavigationBar: RimsBottomNavigation(
        currentTab: _currentTab,
        onTabSelected: (tab) {
          setState(() => _currentTab = tab);
        },
      ),
    );
  }
}
