import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
import '../../../offline/domain/repositories/document_draft_repository.dart';
import '../../../offline/domain/repositories/outbox_repository.dart';
import '../../../offline/domain/entities/outbox_operation.dart';
import '../../../offline/domain/services/outbox_permission_policy.dart';
import '../../../offline/domain/services/outbox_executor.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';
import '../../../offline/domain/services/network_status_service.dart';
import '../../../offline/presentation/view_models/offline_status_view_model.dart';
import '../../../offline/presentation/widgets/offline_status_bar.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../profile/presentation/pages/profile_page.dart';
import '../../../reports/domain/repositories/reports_repository.dart';
import '../../../reports/presentation/pages/reports_page.dart';
import '../../../scanner/data/mobile_scanner_capability.dart';
import '../../../scanner/data/field_operations_scanner.dart';
import '../../../scanner/data/system_scan_feedback.dart';
import '../../../scanner/domain/entities/scan_data.dart';
import '../../../scanner/domain/services/barcode_scanner_capability.dart';
import '../../../scanner/domain/services/scan_lookup_cache.dart';
import '../../../scanner/presentation/pages/scanner_page.dart';
import '../../../scanner/presentation/view_models/scan_session_view_model.dart';
import '../../../scanner/presentation/widgets/keyboard_wedge_listener.dart';
import '../view_models/app_tab.dart';
import '../../../../routes/route_paths.dart';

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
    this.scanLookupCache,
    this.documentDraftRepository,
    this.initialDraftId,
    this.outboxRepository,
    this.offlineOwnershipService,
    this.networkStatusService,
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
  final ScanLookupCache? scanLookupCache;
  final DocumentDraftRepository? documentDraftRepository;
  final String? initialDraftId;
  final OutboxRepository? outboxRepository;
  final OfflineOwnershipService? offlineOwnershipService;
  final NetworkStatusService? networkStatusService;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

final class _AppShellPageState extends State<AppShellPage> {
  static const OutboxPermissionPolicy _outboxPermissionPolicy =
      OutboxPermissionPolicy();
  late AppTab _currentTab;
  String? _pendingDocumentActionLabel;
  bool _pendingDocumentScanner = false;
  StreamSubscription<GlobalRefreshRequestedEvent>? _refreshSubscription;
  final StreamController<String> _wedgeBarcodes = StreamController.broadcast();
  OfflineStatusViewModel? _offlineStatusViewModel;

  @override
  void initState() {
    super.initState();
    _currentTab = widget.initialDraftId == null
        ? AppTab.home
        : AppTab.documents;
    _subscribeToRefreshEvents();
    final networkStatusService = widget.networkStatusService;
    if (networkStatusService != null) {
      _offlineStatusViewModel = OfflineStatusViewModel(
        networkStatusService: networkStatusService,
        outboxRepository: widget.outboxRepository,
        contextReader: () => _outboxExecutionContext,
      );
      widget.sessionController.addListener(_refreshOfflineStatus);
      unawaited(_offlineStatusViewModel!.load());
    }
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
    widget.sessionController.removeListener(_refreshOfflineStatus);
    _offlineStatusViewModel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusViewModel = _offlineStatusViewModel;
    return Scaffold(
      body: Column(
        children: [
          if (statusViewModel != null)
            SafeArea(
              bottom: false,
              child: OfflineStatusBar(
                viewModel: statusViewModel,
                onOpenSyncCenter: () => unawaited(_openSyncCenter()),
              ),
            ),
          Expanded(
            child: KeyboardWedgeListener(
              enabled: _currentTab == AppTab.inventory,
              onBarcode: _wedgeBarcodes.add,
              child: ListenableBuilder(
                listenable: widget.sessionController,
                builder: (context, child) => statusViewModel == null
                    ? _tabBody
                    : ListenableBuilder(
                        listenable: statusViewModel,
                        builder: (context, child) => _tabBody,
                      ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: RimsBottomNavigation(
        currentTab: _currentTab,
        onTabSelected: _selectTab,
      ),
    );
  }

  Widget get _tabBody {
    if (widget.sessionController.isOwnershipTransitioning) {
      return const Center(child: Text('正在保护本机离线数据...'));
    }
    if (!widget.sessionController.canAccessOfflineData &&
        _currentTab != AppTab.profile) {
      return const Center(child: Text('本机离线数据暂不可用，请在个人中心重试'));
    }
    final currentUser = widget.sessionController.currentUser;
    final currentWarehouse = widget.sessionController.currentWarehouse;
    return switch (_currentTab) {
      AppTab.home => HomePage(
        key: ValueKey('home-${currentUser?.id}-${currentWarehouse?.id}'),
        user: currentUser,
        warehouse: currentWarehouse,
        documentsRepository: widget.documentsRepository,
        inventoryRepository: widget.inventoryRepository,
        reportsRepository: widget.reportsRepository,
        eventBus: widget.eventBus,
        onQuickActionSelected: _handleHomeQuickAction,
        onDataFreshnessChanged: (freshness) {
          if (currentUser == null || currentWarehouse == null) return;
          _offlineStatusViewModel?.updateDataFreshness(
            accountId: currentUser.id.toString(),
            warehouseId: currentWarehouse.id,
            permissionStamp: _outboxExecutionContext?.permissionStamp ?? '',
            fetchedAt: freshness?.fetchedAt,
            expiresAt: freshness?.expiresAt,
            hasCachedData: freshness?.hasCachedData ?? false,
          );
        },
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
        key: ValueKey(
          'documents-${widget.sessionController.currentUser?.id}-'
          '${widget.sessionController.currentWarehouse?.id}',
        ),
        repository: widget.documentsRepository,
        inventoryRepository: widget.inventoryRepository,
        currentWarehouse: widget.sessionController.currentWarehouse,
        warehouses: widget.sessionController.warehouses,
        canManageAdminDocumentActions:
            widget.sessionController.currentUser?.isAdmin == true,
        initialActionLabel: _pendingDocumentActionLabel,
        requestScannerOnOpen: _pendingDocumentScanner,
        onScanRequested: _openInventoryScanner,
        eventBus: widget.eventBus,
        attachmentsRepository: widget.attachmentsRepository,
        attachmentPicker: widget.attachmentPicker,
        attachmentStagingStore: widget.attachmentStagingStore,
        attachmentShareService: widget.attachmentShareService,
        attachmentUserId: widget.sessionController.currentUser?.id.toString(),
        draftRepository: widget.documentDraftRepository,
        accountId: widget.sessionController.currentUser?.id.toString(),
        observedRoleCode: widget.sessionController.currentUser?.roleCode ?? '',
        initialDraftId: widget.initialDraftId,
        outboxRepository: widget.outboxRepository,
        allowedOutboxKinds: _allowedOutboxKinds,
        outboxContextReader: () => _outboxExecutionContext,
        outboxContextGenerationReader: () =>
            widget.sessionController.contextGeneration,
        networkReachability: _offlineStatusViewModel?.reachability,
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
        onLogoutRequested: (choice) => _logout(choice),
        previewOfflineData: offlineOwnershipService == null
            ? null
            : ({required accountId, required command}) =>
                  offlineOwnershipService!.preview(
                    accountId: accountId,
                    command: command,
                  ),
        executeOfflineClear: offlineOwnershipService?.executeClear,
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

  Set<OutboxOperationKind> get _allowedOutboxKinds {
    return _outboxExecutionContext?.allowedKinds ?? const {};
  }

  OutboxExecutionContext? get _outboxExecutionContext {
    if (!widget.sessionController.canSync) return null;
    final user = widget.sessionController.currentUser;
    final warehouse = widget.sessionController.currentWarehouse;
    if (user == null || warehouse == null) return null;
    return _outboxPermissionPolicy.contextFor(
      user: user,
      warehouseId: warehouse.id,
    );
  }

  Future<InventoryItem?> _openInventoryScanner(BuildContext context) async {
    final repository = widget.inventoryRepository;
    final user = widget.sessionController.currentUser;
    final warehouse = widget.sessionController.currentWarehouse;
    if (repository == null || user == null || warehouse == null) return null;

    final config = FieldOperationsTestConfig.current;
    final BarcodeScannerCapability scanner;
    final Widget camera;
    if (config.enabled) {
      scanner = FieldOperationsScanner(barcode: config.barcode);
      camera = const ColoredBox(
        key: Key('field-operations-camera'),
        color: Colors.black,
      );
    } else {
      final mobileScanner = MobileScannerCapability();
      scanner = mobileScanner;
      camera = MobileScanner(controller: mobileScanner.controller);
    }
    final viewModel = ScanSessionViewModel(
      inventoryRepository: repository,
      userId: user.id.toString(),
      warehouseId: warehouse.id,
      feedback: SystemScanFeedback(),
      cache: widget.scanLookupCache,
      mode: ScanMode.single,
    );
    try {
      return await Navigator.of(context).push<InventoryItem>(
        MaterialPageRoute(
          builder: (context) => ScannerPage(
            viewModel: viewModel,
            scanner: scanner,
            camera: camera,
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
        _pendingDocumentScanner = false;
      }
    });
  }

  void _handleHomeQuickAction(HomeQuickAction action) {
    setState(() {
      _currentTab = action.targetTab;
      _pendingDocumentActionLabel = action.documentActionLabel;
      _pendingDocumentScanner = action.requestsScanner;
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

  OfflineOwnershipService? get offlineOwnershipService =>
      widget.offlineOwnershipService;

  Future<OfflineOwnershipReport?> _logout([
    DraftRetentionChoice draftRetention = DraftRetentionChoice.delete,
  ]) async {
    return widget.sessionController.logout(
      authRepository: widget.authRepository,
      draftRetention: draftRetention,
    );
  }

  void _subscribeToRefreshEvents() {
    _refreshSubscription = widget.eventBus
        ?.on<GlobalRefreshRequestedEvent>()
        .listen((_) {
          unawaited(_offlineStatusViewModel?.load());
          unawaited(
            widget.sessionController.refreshSession(widget.authRepository),
          );
        });
  }

  void _refreshOfflineStatus() {
    _offlineStatusViewModel?.refreshContext();
    unawaited(_offlineStatusViewModel?.load());
  }

  Future<void> _openSyncCenter() async {
    await context.push(RoutePaths.syncCenter);
    if (!mounted) return;
    await _offlineStatusViewModel?.load();
  }
}
