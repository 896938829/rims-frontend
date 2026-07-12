import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/events/app_event_bus.dart';
import '../features/admin/domain/repositories/admin_repository.dart';
import '../features/attachments/domain/repositories/attachments_repository.dart';
import '../features/attachments/domain/services/attachment_picker.dart';
import '../features/attachments/domain/services/attachment_share_service.dart';
import '../features/attachments/domain/services/attachment_staging_store.dart';
import '../features/auth/domain/repositories/auth_repository.dart';
import '../features/auth/presentation/pages/login_page.dart';
import '../features/auth/presentation/view_models/auth_session_controller.dart';
import '../features/documents/domain/repositories/documents_repository.dart';
import '../features/inventory/domain/repositories/inventory_repository.dart';
import '../features/offline/domain/repositories/document_draft_repository.dart';
import '../features/offline/presentation/view_models/drafts_view_model.dart';
import '../features/offline/presentation/widgets/draft_manager.dart';
import '../features/reports/domain/repositories/reports_repository.dart';
import '../features/scanner/domain/services/scan_lookup_cache.dart';
import '../features/shell/presentation/pages/app_shell_page.dart';
import 'route_paths.dart';

GoRouter createAppRouter({
  required AuthRepository authRepository,
  required AuthSessionController sessionController,
  DocumentsRepository? documentsRepository,
  InventoryRepository? inventoryRepository,
  ReportsRepository? reportsRepository,
  AdminRepository? adminRepository,
  AttachmentsRepository? attachmentsRepository,
  AttachmentPicker? attachmentPicker,
  AttachmentStagingStore? attachmentStagingStore,
  AttachmentShareService? attachmentShareService,
  AppEventBus? eventBus,
  ScanLookupCache? scanLookupCache,
  DocumentDraftRepository? documentDraftRepository,
  String initialLocation = RoutePaths.login,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: sessionController,
    redirect: (context, state) {
      final isAuthenticated = sessionController.isAuthenticated;
      final isLoginRoute = state.matchedLocation == RoutePaths.login;

      if (sessionController.isRestoring) {
        if (!isAuthenticated && !isLoginRoute) {
          return RoutePaths.login;
        }

        return null;
      }

      if (!isAuthenticated && !isLoginRoute) {
        return RoutePaths.login;
      }

      if (isAuthenticated && isLoginRoute) {
        return RoutePaths.shell;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: RoutePaths.login,
        builder: (context, state) => LoginPage(
          authRepository: authRepository,
          sessionController: sessionController,
        ),
      ),
      GoRoute(
        path: RoutePaths.drafts,
        builder: (context, state) => _DraftManagerRoute(
          repository: documentDraftRepository,
          sessionController: sessionController,
          attachmentStagingStore: attachmentStagingStore,
        ),
      ),
      GoRoute(
        path: RoutePaths.shell,
        builder: (context, state) => AppShellPage(
          authRepository: authRepository,
          documentsRepository: documentsRepository,
          inventoryRepository: inventoryRepository,
          reportsRepository: reportsRepository,
          adminRepository: adminRepository,
          attachmentsRepository: attachmentsRepository,
          attachmentPicker: attachmentPicker,
          attachmentStagingStore: attachmentStagingStore,
          attachmentShareService: attachmentShareService,
          eventBus: eventBus,
          sessionController: sessionController,
          scanLookupCache: scanLookupCache,
          documentDraftRepository: documentDraftRepository,
          initialDraftId: state.uri.queryParameters['draft'],
        ),
      ),
    ],
  );
}

final class _DraftManagerRoute extends StatefulWidget {
  const _DraftManagerRoute({
    required this.repository,
    required this.sessionController,
    required this.attachmentStagingStore,
  });

  final DocumentDraftRepository? repository;
  final AuthSessionController sessionController;
  final AttachmentStagingStore? attachmentStagingStore;

  @override
  State<_DraftManagerRoute> createState() => _DraftManagerRouteState();
}

final class _DraftManagerRouteState extends State<_DraftManagerRoute> {
  DraftsViewModel? _viewModel;
  String? _accountId;
  String? _roleCode;
  int? _warehouseId;

  @override
  void initState() {
    super.initState();
    widget.sessionController.addListener(_handleSessionChanged);
    _createViewModel();
  }

  void _createViewModel() {
    final repository = widget.repository;
    final user = widget.sessionController.currentUser;
    final warehouse = widget.sessionController.currentWarehouse;
    if (repository != null && user != null && warehouse != null) {
      _accountId = user.id.toString();
      _roleCode = user.roleCode;
      _warehouseId = warehouse.id;
      _viewModel = DraftsViewModel(
        repository: repository,
        accountId: _accountId!,
        roleCode: _roleCode!,
        warehouseId: _warehouseId!,
        attachmentStagingStore:
            widget.attachmentStagingStore is DraftAttachmentStagingStore
            ? widget.attachmentStagingStore! as DraftAttachmentStagingStore
            : null,
        attachmentUserId: _accountId,
      );
    }
  }

  void _handleSessionChanged() {
    final user = widget.sessionController.currentUser;
    final warehouse = widget.sessionController.currentWarehouse;
    if (user == null || warehouse == null) return;
    final accountId = user.id.toString();
    if (_accountId == accountId &&
        _roleCode == user.roleCode &&
        _warehouseId == warehouse.id) {
      return;
    }
    _accountId = accountId;
    _roleCode = user.roleCode;
    _warehouseId = warehouse.id;
    final viewModel = _viewModel;
    if (viewModel == null) {
      _createViewModel();
      if (mounted) setState(() {});
      return;
    }
    unawaited(
      viewModel.updateContext(
        accountId: accountId,
        roleCode: user.roleCode,
        warehouseId: warehouse.id,
      ),
    );
  }

  @override
  void dispose() {
    widget.sessionController.removeListener(_handleSessionChanged);
    _viewModel?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = _viewModel;
    return Scaffold(
      appBar: AppBar(title: const Text('草稿管理')),
      body: viewModel == null
          ? const Center(child: Text('草稿服务不可用'))
          : SafeArea(
              child: DraftManager(
                viewModel: viewModel,
                warehouseName: _warehouseName,
                onOpen: (draft) => context.go(RoutePaths.openDraft(draft.id)),
              ),
            ),
    );
  }

  String _warehouseName(int warehouseId) {
    for (final warehouse in widget.sessionController.warehouses) {
      if (warehouse.id == warehouseId) return warehouse.name;
    }
    return '仓库 $warehouseId';
  }
}
