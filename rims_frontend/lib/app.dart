import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/events/app_event.dart';
import 'core/events/app_event_bus.dart';
import 'core/network/api_client.dart';
import 'core/network/api_endpoints.dart';
import 'core/storage/app_secure_storage.dart';
import 'core/theme/app_theme.dart';
import 'features/admin/data/datasources/admin_remote_datasource.dart';
import 'features/admin/data/repositories/admin_repository_impl.dart';
import 'features/attachments/data/services/android_attachment_picker.dart';
import 'features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'features/attachments/data/repositories/attachments_repository_impl.dart';
import 'features/attachments/data/services/attachment_share_service.dart';
import 'features/attachments/data/services/file_attachment_staging_store.dart';
import 'features/auth/data/datasources/auth_remote_datasource.dart';
import 'features/auth/data/repositories/auth_repository_impl.dart';
import 'features/auth/presentation/view_models/auth_session_controller.dart';
import 'features/documents/data/datasources/documents_remote_datasource.dart';
import 'features/documents/data/repositories/documents_repository_impl.dart';
import 'features/inventory/data/datasources/inventory_remote_datasource.dart';
import 'features/inventory/data/repositories/inventory_repository_impl.dart';
import 'features/reports/data/datasources/reports_remote_datasource.dart';
import 'features/reports/data/repositories/reports_repository_impl.dart';
import 'features/scanner/domain/services/scan_lookup_cache.dart';
import 'features/scanner/domain/services/scan_session_store.dart';
import 'routes/app_router.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

final class _MainAppState extends State<MainApp> {
  final AuthSessionController _sessionController = AuthSessionController();
  final AppSecureStorage _secureStorage = const AppSecureStorage();
  final AppEventBus _eventBus = AppEventBus();
  final ScanLookupCache _scanLookupCache = ScanLookupCache();
  final ScanSessionStore _scanSessionStore = ScanSessionStore();
  late final AndroidAttachmentPicker _attachmentPicker;
  late final FileAttachmentStagingStore _attachmentStagingStore;
  late final AttachmentsRepositoryImpl _attachmentsRepository;
  late final PlatformAttachmentShareService _attachmentShareService;
  StreamSubscription<TokenExpiredEvent>? _tokenExpiredSubscription;
  late final ApiClient _apiClient;
  late final AuthRepositoryImpl _authRepository;
  late final DocumentsRepositoryImpl _documentsRepository;
  late final InventoryRepositoryImpl _inventoryRepository;
  late final ReportsRepositoryImpl _reportsRepository;
  late final AdminRepositoryImpl _adminRepository;
  late final GoRouter _router;
  String? _activeUserId;

  @override
  void initState() {
    super.initState();
    _sessionController.addListener(_handleSessionOwnership);
    _attachmentPicker = AndroidAttachmentPicker();
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
    _authRepository = AuthRepositoryImpl(
      remoteDataSource: ApiAuthRemoteDataSource(_apiClient),
      secureStorage: _secureStorage,
    );
    _documentsRepository = DocumentsRepositoryImpl(
      remoteDataSource: ApiDocumentsRemoteDataSource(_apiClient),
    );
    _inventoryRepository = InventoryRepositoryImpl(
      remoteDataSource: ApiInventoryRemoteDataSource(_apiClient),
    );
    _reportsRepository = ReportsRepositoryImpl(
      remoteDataSource: ApiReportsRemoteDataSource(_apiClient),
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
    );
    _tokenExpiredSubscription = _eventBus.on<TokenExpiredEvent>().listen((_) {
      unawaited(_authRepository.logout());
      _sessionController.expireSession();
    });
    unawaited(_sessionController.restoreSession(_authRepository));
  }

  @override
  void dispose() {
    _sessionController.removeListener(_handleSessionOwnership);
    unawaited(_tokenExpiredSubscription?.cancel());
    unawaited(_eventBus.dispose());
    _router.dispose();
    _sessionController.dispose();
    super.dispose();
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
