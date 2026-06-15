import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rims_frontend/app.dart';
import 'package:rims_frontend/features/sample/presentation/pages/sample_page.dart';
import 'package:rims_frontend/routes/route_paths.dart';

void main() {
  testWidgets('renders with an injected router config', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: RoutePaths.root,
          builder: (context, state) => const Text('Injected route'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MainApp(routerConfig: router));

    expect(find.text('Injected route'), findsOneWidget);
  });

  testWidgets('keeps router state stable across parent rebuilds',
      (tester) async {
    final hostKey = GlobalKey<_RebuildingHostState>();

    await tester.pumpWidget(_RebuildingHost(key: hostKey));
    await tester.pump();

    GoRouter.of(tester.element(find.byType(SamplePage))).go(RoutePaths.sample);
    await tester.pumpAndSettle();

    expect(_currentRouterPath(tester), RoutePaths.sample);

    hostKey.currentState!.rebuild();
    await tester.pumpAndSettle();

    expect(_currentRouterPath(tester), RoutePaths.sample);
  });
}

String _currentRouterPath(WidgetTester tester) {
  final context = tester.element(find.byType(SamplePage));

  return GoRouter.of(context).routeInformationProvider.value.uri.path;
}

final class _RebuildingHost extends StatefulWidget {
  const _RebuildingHost({super.key});

  @override
  State<_RebuildingHost> createState() => _RebuildingHostState();
}

final class _RebuildingHostState extends State<_RebuildingHost> {
  void rebuild() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Use a fresh widget instance so the test exercises MainApp.build.
    // ignore: prefer_const_constructors
    return MainApp();
  }
}
