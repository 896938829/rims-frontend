import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/events/app_event.dart';
import 'core/events/app_event_bus.dart';
import 'core/network/api_client.dart';
import 'core/network/api_endpoints.dart';
import 'core/result/failure.dart';
import 'core/storage/app_secure_storage.dart';
import 'core/theme/app_theme.dart';
import 'features/admin/data/datasources/admin_remote_datasource.dart';
import 'features/admin/data/repositories/admin_repository_impl.dart';
import 'features/attachments/data/services/android_attachment_picker.dart';
import 'features/attachments/data/services/field_operations_attachment_picker.dart';
import 'features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'features/attachments/data/repositories/attachments_repository_impl.dart';
import 'features/attachments/data/services/attachment_share_service.dart';
import 'features/attachments/data/services/file_attachment_staging_store.dart';
import 'features/attachments/domain/services/attachment_picker.dart';
import 'features/auth/data/datasources/auth_remote_datasource.dart';
import 'features/auth/data/repositories/auth_repository_impl.dart';
import 'features/auth/domain/repositories/auth_repository.dart';
import 'features/auth/presentation/view_models/auth_session_controller.dart';
import 'features/documents/data/datasources/documents_remote_datasource.dart';
import 'features/documents/data/repositories/documents_repository_impl.dart';
import 'features/documents/domain/repositories/documents_repository.dart';
import 'features/inventory/data/datasources/inventory_remote_datasource.dart';
import 'features/inventory/data/repositories/inventory_repository_impl.dart';
import 'features/inventory/domain/repositories/inventory_repository.dart';
import 'features/offline/domain/services/offline_store.dart';
import 'features/offline/data/services/connectivity_network_status_service.dart';
import 'features/offline/data/repositories/cached_auth_repository.dart';
import 'features/offline/data/repositories/cached_inventory_repository.dart';
import 'features/offline/data/repositories/cached_documents_repository.dart';
import 'features/offline/data/repositories/cached_reports_repository.dart';
import 'features/offline/data/repositories/drift_document_draft_repository.dart';
import 'features/offline/domain/repositories/document_draft_repository.dart';
import 'features/offline/domain/services/network_status_service.dart';
import 'features/reports/data/datasources/reports_remote_datasource.dart';
import 'features/reports/data/repositories/reports_repository_impl.dart';
import 'features/reports/domain/repositories/reports_repository.dart';
import 'features/scanner/domain/services/scan_lookup_cache.dart';
import 'features/scanner/domain/services/scan_session_store.dart';
import 'features/scanner/data/field_operations_scanner.dart';
import 'routes/app_router.dart';

class MainApp extends StatefulWidget {
  const MainApp({
    required this.offlineStore,
    this.networkStatusService,
    super.key,
  });

  final OfflineStore offlineStore;
  final NetworkStatusService? networkStatusService;

  @override
  State<MainApp> createState() => _MainAppState();
}

final class _MainAppState extends State<MainApp> {
  late final AuthSessionController _sessionController;
  final AppSecureStorage _secureStorage = const AppSecureStorage();
  final AppEventBus _eventBus = AppEventBus();
  late final ScanLookupCache _scanLookupCache;
  final ScanSessionStore _scanSessionStore = ScanSessionStore();
  late final AttachmentPicker _attachmentPicker;
  late final FileAttachmentStagingStore _attachmentStagingStore;
  late final AttachmentsRepositoryImpl _attachmentsRepository;
  late final PlatformAttachmentShareService _attachmentShareService;
  StreamSubscription<TokenExpiredEvent>? _tokenExpiredSubscription;
  StreamSubscription<AccountOwnershipChangedEvent>?
  _accountOwnershipSubscription;
  StreamSubscription<WarehouseOwnershipChangedEvent>?
  _warehouseOwnershipSubscription;
  late final ApiClient _apiClient;
  late final AuthRepository _authRepository;
  late final DocumentsRepository _documentsRepository;
  late final InventoryRepository _inventoryRepository;
  late final ReportsRepository _reportsRepository;
  late final DocumentDraftRepository _documentDraftRepository;
  late final AdminRepositoryImpl _adminRepository;
  late final GoRouter _router;
  late final NetworkStatusService _networkStatusService;
  Dio? _healthClient;
  String? _activeUserId;

  @override
  void initState() {
    super.initState();
    _sessionController = AuthSessionController(eventBus: _eventBus);
    _scanLookupCache = ScanLookupCache(offlineStore: widget.offlineStore);
    _sessionController.addListener(_handleSessionOwnership);
    _networkStatusService =
        widget.networkStatusService ?? _createNetworkStatusService();
    final fieldConfig = FieldOperationsTestConfig.current;
    _attachmentPicker = fieldConfig.enabled
        ? FieldOperationsAttachmentPicker(
            rootDirectory: getTemporaryDirectory,
            providerToken: fieldConfig.pickedFile,
          )
        : AndroidAttachmentPicker();
    _attachmentStagingStore = FileAttachmentStagingStore(
      rootDirectory: getApplicationSupportDirectory,
      idFactory: const Uuid().v4,
    );
    _attachmentShareService = PlatformAttachmentShareService();
    unawaited(_attachmentPicker.recoverLostData());
    unawaited(
      _attachmentStagingStore.cleanupStale(maxAge: const Duration(days: 7)),
    );
    _apiClient = ApiClient(
      tokenReader: () async =>
          _sessionController.accessToken ??
          await _secureStorage.readAccessToken(),
      warehouseIdReader: () async => _sessionController.currentWarehouse?.id,
      eventBus: _eventBus,
      requestObserver: (outcome) {
        if (outcome.succeeded) {
          _networkStatusService.markOnlineFromRequest();
        } else if (outcome.failure is NetworkFailure) {
          unawaited(_networkStatusService.verify());
        }
      },
    );
    _attachmentsRepository = AttachmentsRepositoryImpl(
      remoteDataSource: ApiAttachmentsRemoteDataSource(_apiClient),
      apiBaseUri: Uri.parse(ApiEndpoints.baseUrl),
      saveDownload: (attachment, bytes) async {
        final userId = _sessionController.currentUser?.id.toString();
        if (userId == null) {
          throw StateError('Cannot save attachment without an active user.');
        }
        final result = await _attachmentStagingStore.saveDownload(
          userId: userId,
          originalName: attachment.originalName,
          bytes: bytes,
        );
        return result.when(
          success: (path) => path,
          failure: (failure) => throw StateError(failure.message),
        );
      },
    );
    final authRepository = AuthRepositoryImpl(
      remoteDataSource: ApiAuthRemoteDataSource(_apiClient),
      secureStorage: _secureStorage,
    );
    _authRepository = CachedAuthRepository(
      delegate: authRepository,
      store: widget.offlineStore,
      tokenStorage: _secureStorage,
      accountStorage: _secureStorage,
    );
    final documentsRepository = DocumentsRepositoryImpl(
      remoteDataSource: ApiDocumentsRemoteDataSource(_apiClient),
    );
    _documentsRepository = CachedDocumentsRepository(
      delegate: documentsRepository,
      store: widget.offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
    );
    final inventoryRepository = InventoryRepositoryImpl(
      remoteDataSource: ApiInventoryRemoteDataSource(_apiClient),
    );
    _inventoryRepository = CachedInventoryRepository(
      delegate: inventoryRepository,
      store: widget.offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
    );
    final reportsRepository = ReportsRepositoryImpl(
      remoteDataSource: ApiReportsRemoteDataSource(_apiClient),
    );
    _reportsRepository = CachedReportsRepository(
      delegate: reportsRepository,
      store: widget.offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
      canViewFinancialMetricsReader: () =>
          _sessionController.currentUser?.isAdmin == true,
    );
    _documentDraftRepository = DriftDocumentDraftRepository(
      store: widget.offlineStore,
    );
    _adminRepository = AdminRepositoryImpl(
      remoteDataSource: ApiAdminRemoteDataSource(_apiClient),
    );
    _router = createAppRouter(
      authRepository: _authRepository,
      documentsRepository: _documentsRepository,
      inventoryRepository: _inventoryRepository,
      reportsRepository: _reportsRepository,
      adminRepository: _adminRepository,
      attachmentsRepository: _attachmentsRepository,
      attachmentPicker: _attachmentPicker,
      attachmentStagingStore: _attachmentStagingStore,
      attachmentShareService: _attachmentShareService,
      eventBus: _eventBus,
      sessionController: _sessionController,
      scanLookupCache: _scanLookupCache,
      documentDraftRepository: _documentDraftRepository,
    );
    _tokenExpiredSubscription = _eventBus.on<TokenExpiredEvent>().listen((_) {
      unawaited(_authRepository.logout());
      _sessionController.expireSession();
    });
    _accountOwnershipSubscription = _eventBus
        .on<AccountOwnershipChangedEvent>()
        .listen((event) {
          final previous = event.previousAccountId;
          if (previous != null && previous != event.currentAccountId) {
            unawaited(widget.offlineStore.clearAccount(previous));
          }
        });
    _warehouseOwnershipSubscription = _eventBus
        .on<WarehouseOwnershipChangedEvent>()
        .listen((event) {
          final previous = event.previousWarehouseId;
          if (previous != null && previous != event.currentWarehouseId) {
            unawaited(
              widget.offlineStore.invalidateWarehouseCache(
                accountId: event.accountId,
                warehouseId: previous,
              ),
            );
          }
        });
    unawaited(_sessionController.restoreSession(_authRepository));
    unawaited(_networkStatusService.verify());
  }

  @override
  void dispose() {
    _sessionController.removeListener(_handleSessionOwnership);
    final picker = _attachmentPicker;
    if (picker is FieldOperationsAttachmentPicker) {
      unawaited(picker.cleanup());
    }
    unawaited(_tokenExpiredSubscription?.cancel());
    unawaited(_accountOwnershipSubscription?.cancel());
    unawaited(_warehouseOwnershipSubscription?.cancel());
    unawaited(_eventBus.dispose());
    unawaited(_networkStatusService.dispose());
    _healthClient?.close(force: true);
    _router.dispose();
    _sessionController.dispose();
    super.dispose();
  }

  NetworkStatusService _createNetworkStatusService() {
    final connectivity = Connectivity();
    final healthClient = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        sendTimeout: const Duration(seconds: 3),
        validateStatus: (_) => true,
      ),
    );
    _healthClient = healthClient;
    return ConnectivityNetworkStatusService(
      checkConnectivity: connectivity.checkConnectivity,
      connectivityChanges: connectivity.onConnectivityChanged,
      healthProbe: () async {
        final response = await healthClient.getUri<Object?>(
          ApiEndpoints.healthUri,
        );
        return response.statusCode == 200;
      },
    );
  }

  void _handleSessionOwnership() {
    final nextUserId = _sessionController.session?.user.id.toString();
    final previousUserId = _activeUserId;
    _activeUserId = nextUserId;
    if (previousUserId == null || previousUserId == nextUserId) {
      return;
    }
    unawaited(_scanLookupCache.clearForUser(previousUserId));
    unawaited(_scanSessionStore.clearForUser(previousUserId));
    unawaited(_attachmentStagingStore.clearForUser(previousUserId));
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
