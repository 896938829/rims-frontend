import 'package:flutter/material.dart';

import 'core/resources/app_strings.dart';
import 'core/theme/app_theme.dart';
import 'routes/app_router.dart';

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = createAppRouter();

    return MaterialApp.router(
      title: AppStrings.appName,
      theme: AppTheme.light,
      routerConfig: router,
    );
  }
}
