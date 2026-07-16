import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/services/offline_store.dart';
import '../database/offline_database_factory.dart';

Future<OfflineStore> createOfflineStore({
  required OfflineDatabaseKeyStorage secureStorage,
}) async {
  final directory = await getApplicationSupportDirectory();
  final factory = OfflineDatabaseFactory(
    readKey: secureStorage.readOfflineDatabaseKey,
    writeKey: secureStorage.saveOfflineDatabaseKey,
  );
  return factory.openNative(
    '${directory.path}${Platform.pathSeparator}rims_offline.sqlite',
  );
}
