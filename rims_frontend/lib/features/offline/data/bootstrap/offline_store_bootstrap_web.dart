import '../../domain/services/offline_store.dart';
import '../repositories/memory_offline_store.dart';

Future<OfflineStore> createOfflineStore() async => MemoryOfflineStore();
