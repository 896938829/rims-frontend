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
import '../features/reports/domain/repositories/reports_repository.dart';
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
        ),
      ),
    ],
  );
}
