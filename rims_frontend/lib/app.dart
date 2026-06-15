import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/resources/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'routes/app_router.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key, this.routerConfig});

  final GoRouter? routerConfig;

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  late final bool _ownsRouter = widget.routerConfig == null;
  late final GoRouter _router = widget.routerConfig ?? createAppRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppStrings.appName,
      theme: AppTheme.light,
      routerConfig: _router,
    );
  }

  @override
  void dispose() {
    if (_ownsRouter) {
      _router.dispose();
    }
    super.dispose();
  }
}
