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
import 'core/result/result.dart';
import 'core/storage/app_secure_storage.dart';
import 'core/storage/pending_revocation_journal.dart';
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
import 'features/offline/data/bootstrap/offline_runtime_bindings.dart';
import 'features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'features/offline/data/services/api_reachability_observer.dart';
import 'features/offline/data/services/attachment_outbox_handler.dart';
import 'features/offline/data/services/connectivity_network_status_service.dart';
import 'features/offline/data/services/document_outbox_handler.dart';
import 'features/offline/data/services/outbox_cleanup_coordinator.dart';
import 'features/offline/data/services/outbox_review_invalidator.dart';
import 'features/offline/data/services/offline_scan_ownership_adapter.dart';
import 'features/offline/data/repositories/cached_auth_repository.dart';
import 'features/offline/data/repositories/cached_inventory_repository.dart';
import 'features/offline/data/repositories/cached_documents_repository.dart';
import 'features/offline/data/repositories/cached_reports_repository.dart';
import 'features/offline/data/repositories/drift_document_draft_repository.dart';
import 'features/offline/domain/repositories/document_draft_repository.dart';
import 'features/offline/domain/repositories/outbox_repository.dart';
import 'features/offline/domain/entities/outbox_operation.dart';
import 'features/offline/domain/services/offline_store.dart';
import 'features/offline/domain/entities/outbox_cleanup_intent.dart';
import 'features/offline/domain/services/network_status_service.dart';
import 'features/offline/domain/services/attachment_staging_protection.dart';
import 'features/offline/domain/services/outbox_executor.dart';
import 'features/offline/domain/services/outbox_permission_policy.dart';
import 'features/offline/domain/services/offline_ownership_service.dart';
import 'features/offline/domain/services/offline_write_barrier.dart';
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
    this.outboxHandlers = const [],
    this.offlineDatabaseKeyManager,
    super.key,
  });

  final OfflineStore offlineStore;
  final NetworkStatusService? networkStatusService;
  final List<OutboxOperationHandler> outboxHandlers;
  final OfflineDatabaseKeyManager? offlineDatabaseKeyManager;

  @override
  State<MainApp> createState() => _MainAppState();
}

final class _MainAppState extends State<MainApp> {
  late final AuthSessionController _sessionController;
  final AppSecureStorage _secureStorage = const AppSecureStorage();
  final AppEventBus _eventBus = AppEventBus();
  final OutboxPermissionPolicy _outboxPermissionPolicy =
      const OutboxPermissionPolicy();
  final OfflineWriteBarrier _offlineWriteBarrier = OfflineWriteBarrier();
  late final OfflineStore _offlineStore;
  late final ScanLookupCache _scanLookupCache;
  late final ScanSessionStore _scanSessionStore;
  late final AttachmentPicker _attachmentPicker;
  late final FileAttachmentStagingStore _attachmentStagingStore;
  late final AttachmentsRepositoryImpl _attachmentsRepository;
  late final PlatformAttachmentShareService _attachmentShareService;
  StreamSubscription<TokenExpiredEvent>? _tokenExpiredSubscription;
  late final ApiClient _apiClient;
  late final AuthRepository _authRepository;
  late final DocumentsRepository _documentsRepository;
  late final InventoryRepository _inventoryRepository;
  late final ReportsRepository _reportsRepository;
  late final DocumentDraftRepository _documentDraftRepository;
  late final OutboxRepository _outboxRepository;
  late final OperationStatusRemoteDataSource _operationStatusDataSource;
  late final OutboxExecutor _outboxExecutor;
  late final OutboxCleanupCoordinator _outboxCleanupCoordinator;
  late final OfflineOwnershipService _offlineOwnershipService;
  late final AdminRepositoryImpl _adminRepository;
  late final GoRouter _router;
  late final NetworkStatusService _networkStatusService;
  Dio? _healthClient;

  @override
  void initState() {
    super.initState();
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
      writeBarrier: _offlineWriteBarrier,
    );
    _offlineStore = WriteBarrierOfflineStore(
      delegate: widget.offlineStore,
      barrier: _offlineWriteBarrier,
    );
    final ownershipOutboxRepository = outboxRepositoryForOfflineStore(
      widget.offlineStore,
    );
    _outboxRepository = WriteBarrierOutboxRepository(
      delegate: ownershipOutboxRepository,
      barrier: _offlineWriteBarrier,
    );
    _scanSessionStore = ScanSessionStore(writeBarrier: _offlineWriteBarrier);
    _scanLookupCache = ScanLookupCache(
      offlineStore: widget.offlineStore,
      writeBarrier: _offlineWriteBarrier,
    );
    final ownershipStore = widget.offlineStore;
    if (ownershipStore is! OfflineOwnershipStore) {
      throw StateError('Offline store must support ownership operations.');
    }
    final databaseKeyManager =
        widget.offlineDatabaseKeyManager ??
        createOfflineDatabaseKeyManager(
          store: widget.offlineStore,
          readKey: _secureStorage.readOfflineDatabaseKey,
          writeKey: _secureStorage.saveOfflineDatabaseKey,
        );
    _offlineOwnershipService = OfflineOwnershipService(
      store: ownershipStore as OfflineOwnershipStore,
      files: createOfflineOwnedFileStore(_attachmentStagingStore),
      scans: OfflineScanOwnershipAdapter(
        sessions: _scanSessionStore,
        lookupCache: _scanLookupCache,
      ),
      reviews: OutboxReviewInvalidator(repository: ownershipOutboxRepository),
      databaseKeys: databaseKeyManager,
      mutationParticipants: [_offlineWriteBarrier],
    );
    _sessionController = AuthSessionController(
      eventBus: _eventBus,
      ownershipCoordinator: _offlineOwnershipService,
    );
    _attachmentShareService = PlatformAttachmentShareService();
    unawaited(_attachmentPicker.recoverLostData());
    _apiClient = ApiClient(
      tokenReader: () async => _sessionController.canAuthenticateRequests
          ? _sessionController.accessToken ??
                await _secureStorage.readAccessToken()
          : null,
      warehouseIdReader: () async => _sessionController.currentWarehouse?.id,
      eventBus: _eventBus,
      requestObserver: ApiReachabilityObserver(_networkStatusService).call,
    );
    final attachmentsRemoteDataSource = ApiAttachmentsRemoteDataSource(
      _apiClient,
    );
    _attachmentsRepository = AttachmentsRepositoryImpl(
      remoteDataSource: attachmentsRemoteDataSource,
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
      store: _offlineStore,
      tokenStorage: _secureStorage,
      accountStorage: _secureStorage,
      revocationStorage: _secureStorage,
      revocationJournal: SharedPreferencesPendingRevocationJournal(),
      ownershipCoordinator: _offlineOwnershipService,
      authEpochReader: () => _sessionController.authEpoch,
      onSessionRevoked: _sessionController.invalidateRevokedSession,
      onSessionExpired: _sessionController.invalidateExpiredSession,
    );
    final documentsRemoteDataSource = ApiDocumentsRemoteDataSource(_apiClient);
    final documentsRepository = DocumentsRepositoryImpl(
      remoteDataSource: documentsRemoteDataSource,
    );
    _documentsRepository = CachedDocumentsRepository(
      delegate: documentsRepository,
      store: _offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
    );
    final inventoryRepository = InventoryRepositoryImpl(
      remoteDataSource: ApiInventoryRemoteDataSource(_apiClient),
    );
    _inventoryRepository = CachedInventoryRepository(
      delegate: inventoryRepository,
      store: _offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
    );
    final reportsRepository = ReportsRepositoryImpl(
      remoteDataSource: ApiReportsRemoteDataSource(_apiClient),
    );
    _reportsRepository = CachedReportsRepository(
      delegate: reportsRepository,
      store: _offlineStore,
      accountIdReader: () => _sessionController.currentUser?.id.toString(),
      warehouseIdReader: () => _sessionController.currentWarehouse?.id,
      canViewFinancialMetricsReader: () =>
          _sessionController.currentUser?.isAdmin == true,
    );
    _documentDraftRepository = DriftDocumentDraftRepository(
      store: _offlineStore,
    );
    _operationStatusDataSource = ApiOperationStatusRemoteDataSource(_apiClient);
    final handlers = <OutboxOperationKind, OutboxOperationHandler>{
      OutboxOperationKind.attachmentUpload: AttachmentOutboxHandler(
        remoteDataSource: attachmentsRemoteDataSource,
        stagingStore: _attachmentStagingStore,
        draftRepository: _documentDraftRepository,
        eventBus: _eventBus,
      ),
      for (final kind in const [
        OutboxOperationKind.documentReference,
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.documentComplete,
        OutboxOperationKind.stocktakeConfirm,
        OutboxOperationKind.stocktakeSettle,
      ])
        kind: DocumentOutboxHandler(
          kind: kind,
          remoteDataSource: documentsRemoteDataSource,
          stagingStore: _attachmentStagingStore,
          draftRepository: _documentDraftRepository,
          eventBus: _eventBus,
        ),
      for (final handler in widget.outboxHandlers) handler.kind: handler,
    };
    _outboxCleanupCoordinator = OutboxCleanupCoordinator(
      repository: _outboxRepository,
      stagingStore: _attachmentStagingStore,
      draftRepository: _documentDraftRepository,
      eventBus: _eventBus,
    );
    _outboxExecutor = OutboxExecutor(
      repository: _outboxRepository,
      networkStatusService: _networkStatusService,
      statusDataSource: _operationStatusDataSource,
      handlers: handlers.values,
      contextReader: _outboxExecutionContext,
      onSuccessPersisted: _outboxCleanupCoordinator.run,
      writeBarrier: _offlineWriteBarrier,
    );
    _offlineOwnershipService.attachMutationParticipant(_outboxExecutor);
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
      outboxRepository: _outboxRepository,
      outboxExecutor: _outboxExecutor,
      offlineOwnershipService: _offlineOwnershipService,
      networkStatusService: _networkStatusService,
    );
    _tokenExpiredSubscription = _eventBus.on<TokenExpiredEvent>().listen((_) {
      unawaited(
        _sessionController.expireSession(authRepository: _authRepository),
      );
    });
    unawaited(_restoreSessionAndMaintain());
    unawaited(_networkStatusService.verify());
  }

  OutboxExecutionContext? _outboxExecutionContext() {
    if (!_sessionController.canSync) return null;
    final user = _sessionController.currentUser;
    final warehouse = _sessionController.currentWarehouse;
    if (user == null || warehouse == null) return null;
    return _outboxPermissionPolicy.contextFor(
      user: user,
      warehouseId: warehouse.id,
    );
  }

  @override
  void dispose() {
    final picker = _attachmentPicker;
    if (picker is FieldOperationsAttachmentPicker) {
      unawaited(picker.cleanup());
    }
    unawaited(_tokenExpiredSubscription?.cancel());
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

  Future<void> _restoreSessionAndMaintain() async {
    await _sessionController.restoreSession(_authRepository);
    final accountId = _sessionController.currentUser?.id.toString();
    if (accountId != null &&
        _sessionController.canAccessOfflineData &&
        kSupportsOfflineFileMaintenance) {
      await _maintainOfflineFiles(accountId);
    }
  }

  Future<void> _maintainOfflineFiles(String accountId) async {
    await _outboxCleanupCoordinator.run(accountId);
    final protected = <String>{};
    try {
      final drafts = await _documentDraftRepository.list(accountId);
      for (final draft in drafts) {
        protected.addAll(draft.attachmentStagingIds);
      }
    } on Object {
      return;
    }
    final listed = await _outboxRepository.list(accountId);
    if (listed case FailureResult<List<OutboxOperation>>()) return;
    protected.addAll(
      AttachmentStagingProtection.requestIdsFor(
        (listed as Success<List<OutboxOperation>>).data,
      ),
    );
    final intents = await _outboxRepository.listCleanupIntents(accountId);
    if (intents case FailureResult<List<OutboxCleanupIntent>>()) return;
    for (final intent in (intents as Success<List<OutboxCleanupIntent>>).data) {
      protected.addAll(intent.attachmentRequestIds);
    }
    await _attachmentStagingStore.cleanupStale(
      userId: accountId,
      maxAge: const Duration(days: 7),
      protectedRequestIds: protected,
    );
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

OutboxRepository outboxRepositoryForOfflineStore(OfflineStore store) {
  return createOutboxRepository(store);
}
