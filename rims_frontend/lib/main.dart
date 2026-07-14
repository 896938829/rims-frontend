import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/config/app_environment.dart';
import 'features/offline/data/bootstrap/offline_store_bootstrap.dart';

export 'app.dart' show MainApp;

Future<void> main() async {
  final configuration = AppConfiguration.fromCompileTimeDefines(
    isReleaseMode: kReleaseMode,
  );
  WidgetsFlutterBinding.ensureInitialized();
  final offlineStore = await createOfflineStore();
  runApp(MainApp(offlineStore: offlineStore, configuration: configuration));
}
