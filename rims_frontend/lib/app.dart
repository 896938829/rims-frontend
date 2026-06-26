import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/network/api_client.dart';
import 'core/storage/app_secure_storage.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/datasources/auth_remote_datasource.dart';
import 'features/auth/data/repositories/auth_repository_impl.dart';
import 'features/auth/presentation/view_models/auth_session_controller.dart';
import 'features/inventory/data/datasources/inventory_remote_datasource.dart';
import 'features/inventory/data/repositories/inventory_repository_impl.dart';
import 'routes/app_router.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

final class _MainAppState extends State<MainApp> {
  final AuthSessionController _sessionController = AuthSessionController();
  final AppSecureStorage _secureStorage = const AppSecureStorage();
  late final ApiClient _apiClient;
  late final AuthRepositoryImpl _authRepository;
  late final InventoryRepositoryImpl _inventoryRepository;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(
      tokenReader: () async =>
          _sessionController.accessToken ??
          await _secureStorage.readAccessToken(),
      warehouseIdReader: () async => _sessionController.currentWarehouse?.id,
    );
    _authRepository = AuthRepositoryImpl(
      remoteDataSource: ApiAuthRemoteDataSource(_apiClient),
      secureStorage: _secureStorage,
    );
    _inventoryRepository = InventoryRepositoryImpl(
      remoteDataSource: ApiInventoryRemoteDataSource(_apiClient),
    );
    _router = createAppRouter(
      authRepository: _authRepository,
      inventoryRepository: _inventoryRepository,
      sessionController: _sessionController,
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _sessionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'RIMS',
      theme: AppTheme.light,
      routerConfig: _router,
    );
  }
}
