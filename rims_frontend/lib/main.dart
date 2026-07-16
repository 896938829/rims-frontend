import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/config/app_environment.dart';
import 'core/storage/app_secure_storage.dart';
import 'features/offline/data/bootstrap/offline_store_bootstrap.dart';

export 'app.dart' show MainApp;

Future<void> main() async {
  final configuration = AppConfiguration.fromCompileTimeDefines(
    isReleaseMode: kReleaseMode,
  );
  WidgetsFlutterBinding.ensureInitialized();
  final secureStorage = AppSecureStorage();
  final offlineStore = await createOfflineStore(secureStorage: secureStorage);
  runApp(
    MainApp(
      offlineStore: offlineStore,
      configuration: configuration,
      secureStorage: secureStorage,
    ),
  );
}
