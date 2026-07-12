import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/widgets/rims_bottom_navigation.dart';
import '../../../admin/domain/repositories/admin_repository.dart';
import '../../../attachments/domain/repositories/attachments_repository.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../../../attachments/domain/services/attachment_share_service.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../../../auth/domain/repositories/auth_repository.dart';
import '../../../auth/presentation/view_models/auth_session_controller.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../../documents/presentation/pages/documents_page.dart';
import '../../../home/presentation/pages/home_page.dart';
import '../../../home/presentation/view_models/home_view_model.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../inventory/presentation/pages/inventory_page.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../profile/presentation/pages/profile_page.dart';
import '../../../reports/domain/repositories/reports_repository.dart';
import '../../../reports/presentation/pages/reports_page.dart';
import '../../../scanner/data/mobile_scanner_capability.dart';
import '../../../scanner/data/system_scan_feedback.dart';
import '../../../scanner/domain/entities/scan_data.dart';
import '../../../scanner/presentation/pages/scanner_page.dart';
import '../../../scanner/presentation/view_models/scan_session_view_model.dart';
import '../../../scanner/presentation/widgets/keyboard_wedge_listener.dart';
import '../view_models/app_tab.dart';

final class AppShellPage extends StatefulWidget {
  const AppShellPage({
    required this.authRepository,
    required this.sessionController,
    this.documentsRepository,
    this.inventoryRepository,
    this.reportsRepository,
    this.adminRepository,
    this.attachmentsRepository,
    this.attachmentPicker,
    this.attachmentStagingStore,
    this.attachmentShareService,
    this.eventBus,
    super.key,
  });

  final AuthRepository authRepository;
  final AuthSessionController sessionController;
  final DocumentsRepository? documentsRepository;
  final InventoryRepository? inventoryRepository;
  final ReportsRepository? reportsRepository;
  final AdminRepository? adminRepository;
  final AttachmentsRepository? attachmentsRepository;
  final AttachmentPicker? attachmentPicker;
  final AttachmentStagingStore? attachmentStagingStore;
  final AttachmentShareService? attachmentShareService;
  final AppEventBus? eventBus;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

final class _AppShellPageState extends State<AppShellPage> {
  AppTab _currentTab = AppTab.home;
  String? _pendingDocumentActionLabel;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;
  final StreamController<String> _wedgeBarcodes = StreamController.broadcast();

  @override
  void initState() {
    super.initState();
    _subscribeToRefreshEvents();
  }

  @override
  void didUpdateWidget(covariant AppShellPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.eventBus != oldWidget.eventBus) {
      unawaited(_refreshSubscription?.cancel());
      _subscribeToRefreshEvents();
    }
  }

  @override
  void dispose() {
    unawaited(_refreshSubscription?.cancel());
    unawaited(_wedgeBarcodes.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: KeyboardWedgeListener(
        enabled: _currentTab == AppTab.inventory,
        onBarcode: _wedgeBarcodes.add,
        child: ListenableBuilder(
          listenable: widget.sessionController,
          builder: (context, child) => _tabBody,
        ),
      ),
      bottomNavigationBar: RimsBottomNavigation(
        currentTab: _currentTab,
        onTabSelected: _selectTab,
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
        reportsRepository: widget.reportsRepository,
        eventBus: widget.eventBus,
        onQuickActionSelected: _handleHomeQuickAction,
      ),
      AppTab.inventory => InventoryPage(
        repository: widget.inventoryRepository,
        documentsRepository: widget.documentsRepository,
        warehouseName:
            widget.sessionController.currentWarehouse?.name ?? '未选择仓库',
        canManageInventorySettings:
            widget.sessionController.currentUser?.isAdmin == true,
        eventBus: widget.eventBus,
        onScanRequested: _openInventoryScanner,
        barcodeInputs: _wedgeBarcodes.stream,
      ),
      AppTab.documents => DocumentsPage(
        repository: widget.documentsRepository,
        inventoryRepository: widget.inventoryRepository,
        currentWarehouse: widget.sessionController.currentWarehouse,
        warehouses: widget.sessionController.warehouses,
        canManageAdminDocumentActions:
            widget.sessionController.currentUser?.isAdmin == true,
        initialActionLabel: _pendingDocumentActionLabel,
        eventBus: widget.eventBus,
        attachmentsRepository: widget.attachmentsRepository,
        attachmentPicker: widget.attachmentPicker,
        attachmentStagingStore: widget.attachmentStagingStore,
        attachmentShareService: widget.attachmentShareService,
        attachmentUserId: widget.sessionController.currentUser?.id.toString(),
      ),
      AppTab.reports => ReportsPage(
        repository: widget.reportsRepository,
        canViewFinancialMetrics:
            widget.sessionController.currentUser?.isAdmin == true,
        eventBus: widget.eventBus,
      ),
      AppTab.profile => ProfilePage(
        user: widget.sessionController.currentUser,
        warehouse: widget.sessionController.currentWarehouse,
        warehouses: widget.sessionController.warehouses,
        isSwitchingWarehouse: widget.sessionController.isSwitchingWarehouse,
        warehouseSwitchMessage:
            widget.sessionController.switchWarehouseFailure?.message,
        onWarehouseSelected: (warehouse) {
          unawaited(_switchWarehouse(warehouse));
        },
        onLogout: () {
          unawaited(_logout());
        },
        adminRepository: widget.adminRepository,
        attachmentsRepository: widget.attachmentsRepository,
        attachmentPicker: widget.attachmentPicker,
        attachmentStagingStore: widget.attachmentStagingStore,
        attachmentShareService: widget.attachmentShareService,
        attachmentUserId: widget.sessionController.currentUser?.id.toString(),
        eventBus: widget.eventBus,
      ),
    };
  }

  Future<InventoryItem?> _openInventoryScanner(BuildContext context) async {
    final repository = widget.inventoryRepository;
    final user = widget.sessionController.currentUser;
    final warehouse = widget.sessionController.currentWarehouse;
    if (repository == null || user == null || warehouse == null) return null;

    final scanner = MobileScannerCapability();
    final viewModel = ScanSessionViewModel(
      inventoryRepository: repository,
      userId: user.id.toString(),
      warehouseId: warehouse.id,
      feedback: SystemScanFeedback(),
      mode: ScanMode.single,
    );
    try {
      return await Navigator.of(context).push<InventoryItem>(
        MaterialPageRoute(
          builder: (context) => ScannerPage(
            viewModel: viewModel,
            scanner: scanner,
            camera: MobileScanner(controller: scanner.controller),
            returnSingleResult: true,
          ),
        ),
      );
    } finally {
      viewModel.dispose();
    }
  }

  void _selectTab(AppTab tab) {
    setState(() {
      _currentTab = tab;
      if (tab != AppTab.documents) {
        _pendingDocumentActionLabel = null;
      }
    });
  }

  void _handleHomeQuickAction(HomeQuickAction action) {
    setState(() {
      _currentTab = action.targetTab;
      _pendingDocumentActionLabel = action.documentActionLabel;
    });
  }

  Future<void> _switchWarehouse(Warehouse warehouse) async {
    final switched = await widget.sessionController.switchWarehouse(
      authRepository: widget.authRepository,
      warehouse: warehouse,
    );

    if (switched) {
      widget.eventBus?.publish(const GlobalRefreshRequestedEvent());
    }
  }

  Future<void> _logout() async {
    await widget.authRepository.logout();
    if (!mounted) {
      return;
    }

    widget.sessionController.logout();
  }

  void _subscribeToRefreshEvents() {
    _refreshSubscription = widget.eventBus
        ?.on<GlobalRefreshRequestedEvent>()
        .listen((_) {
          unawaited(
            widget.sessionController.refreshSession(widget.authRepository),
          );
        });
  }
}
