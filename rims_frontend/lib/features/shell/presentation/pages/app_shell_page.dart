import 'package:flutter/material.dart';

import '../../../../core/widgets/rims_bottom_navigation.dart';
import '../view_models/app_tab.dart';

final class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key});

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

final class _AppShellPageState extends State<AppShellPage> {
  AppTab _currentTab = AppTab.home;

  static const Map<AppTab, Widget> _tabBodies = {
    AppTab.home: Center(child: Text('首页')),
    AppTab.inventory: Center(child: Text('库存')),
    AppTab.documents: Center(child: Text('单据')),
    AppTab.reports: Center(child: Text('报表')),
    AppTab.profile: Center(child: Text('我的')),
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
