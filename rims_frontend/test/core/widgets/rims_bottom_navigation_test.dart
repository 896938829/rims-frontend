import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/navigation/app_tab.dart';
import 'package:rims_frontend/core/widgets/rims_bottom_navigation.dart';

void main() {
  testWidgets('bottom navigation exposes stable enum-derived targets', (
    tester,
  ) async {
    AppTab? selectedTab;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: RimsBottomNavigation(
            currentTab: AppTab.home,
            onTabSelected: (tab) => selectedTab = tab,
          ),
        ),
      ),
    );

    for (final tab in AppTab.values) {
      expect(find.byKey(Key('bottom-nav-${tab.name}')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('bottom-nav-inventory')));
    expect(selectedTab, AppTab.inventory);
  });
}
