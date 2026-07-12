import 'package:flutter/material.dart';

import 'app.dart';
import 'features/offline/data/bootstrap/offline_store_bootstrap.dart';

export 'app.dart' show MainApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final offlineStore = await createOfflineStore();
  runApp(MainApp(offlineStore: offlineStore));
}
