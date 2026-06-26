import 'package:flutter/material.dart';

import '../../../../core/widgets/rims_bottom_navigation.dart';
import '../../../auth/presentation/view_models/auth_session_controller.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../../documents/presentation/pages/documents_page.dart';
import '../../../home/presentation/pages/home_page.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../inventory/presentation/pages/inventory_page.dart';
import '../../../profile/presentation/pages/profile_page.dart';
import '../../../reports/domain/repositories/reports_repository.dart';
import '../../../reports/presentation/pages/reports_page.dart';
import '../view_models/app_tab.dart';

final class AppShellPage extends StatefulWidget {
  const AppShellPage({
    required this.sessionController,
    this.documentsRepository,
    this.inventoryRepository,
    this.reportsRepository,
    super.key,
  });

  final AuthSessionController sessionController;
  final DocumentsRepository? documentsRepository;
  final InventoryRepository? inventoryRepository;
  final ReportsRepository? reportsRepository;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

final class _AppShellPageState extends State<AppShellPage> {
  AppTab _currentTab = AppTab.home;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabBody,
      bottomNavigationBar: RimsBottomNavigation(
        currentTab: _currentTab,
        onTabSelected: (tab) {
          setState(() => _currentTab = tab);
        },
      ),
    );
  }

  Widget get _tabBody {
    return switch (_currentTab) {
      AppTab.home => HomePage(
        user: widget.sessionController.currentUser,
        warehouse: widget.sessionController.currentWarehouse,
        documentsRepository: widget.documentsRepository,
        inventoryRepository: widget.inventoryRepository,
      ),
      AppTab.inventory => InventoryPage(
        repository: widget.inventoryRepository,
        warehouseName:
            widget.sessionController.currentWarehouse?.name ?? '未选择仓库',
      ),
      AppTab.documents => DocumentsPage(repository: widget.documentsRepository),
      AppTab.reports => ReportsPage(repository: widget.reportsRepository),
      AppTab.profile => ProfilePage(
        user: widget.sessionController.currentUser,
        warehouse: widget.sessionController.currentWarehouse,
        onLogout: widget.sessionController.logout,
      ),
    };
  }
}
