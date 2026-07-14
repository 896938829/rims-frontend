import 'package:flutter/widgets.dart';

import 'app_environment.dart';

final class AppConfigurationScope extends InheritedWidget {
  const AppConfigurationScope({
    required this.configuration,
    required super.child,
    super.key,
  });

  final AppConfiguration configuration;

  static AppConfiguration of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw StateError('AppConfigurationScope is missing.');
    }
    return scope.configuration;
  }

  static AppConfigurationScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppConfigurationScope>();
  }

  @override
  bool updateShouldNotify(AppConfigurationScope oldWidget) {
    return configuration != oldWidget.configuration;
  }
}
