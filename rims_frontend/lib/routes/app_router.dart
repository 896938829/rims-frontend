import 'package:go_router/go_router.dart';

import '../features/sample/presentation/pages/sample_page.dart';
import 'route_paths.dart';

GoRouter createAppRouter() {
  return GoRouter(
    initialLocation: RoutePaths.root,
    routes: [
      GoRoute(
        path: RoutePaths.root,
        builder: (context, state) => const SamplePage(),
      ),
      GoRoute(
        path: RoutePaths.sample,
        builder: (context, state) => const SamplePage(),
      ),
    ],
  );
}
