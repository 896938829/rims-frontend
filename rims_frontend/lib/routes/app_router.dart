import 'package:go_router/go_router.dart';

import '../features/auth/presentation/pages/login_page.dart';
import '../features/shell/presentation/pages/app_shell_page.dart';
import 'route_paths.dart';

GoRouter createAppRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: RoutePaths.login,
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: RoutePaths.shell,
        builder: (context, state) => const AppShellPage(),
      ),
    ],
  );
}
