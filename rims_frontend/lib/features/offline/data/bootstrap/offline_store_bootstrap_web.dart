import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/services/offline_store.dart';
import '../repositories/memory_offline_store.dart';

Future<OfflineStore> createOfflineStore({
  required OfflineDatabaseKeyStorage secureStorage,
}) async => MemoryOfflineStore();
