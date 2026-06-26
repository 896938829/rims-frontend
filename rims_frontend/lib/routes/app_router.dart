import 'package:go_router/go_router.dart';

import '../features/auth/domain/repositories/auth_repository.dart';
import '../features/auth/presentation/pages/login_page.dart';
import '../features/auth/presentation/view_models/auth_session_controller.dart';
import '../features/inventory/domain/repositories/inventory_repository.dart';
import '../features/shell/presentation/pages/app_shell_page.dart';
import 'route_paths.dart';

GoRouter createAppRouter({
  required AuthRepository authRepository,
  required AuthSessionController sessionController,
  InventoryRepository? inventoryRepository,
  String initialLocation = RoutePaths.login,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: sessionController,
    redirect: (context, state) {
      final isAuthenticated = sessionController.isAuthenticated;
      final isLoginRoute = state.matchedLocation == RoutePaths.login;

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
          inventoryRepository: inventoryRepository,
          sessionController: sessionController,
        ),
      ),
    ],
  );
}
