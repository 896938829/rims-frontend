import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';

final class AuthSessionController extends ChangeNotifier {
  AuthSessionController({this.eventBus, this.ownershipCoordinator});

  final AppEventBus? eventBus;
  final OfflineOwnershipCoordinator? ownershipCoordinator;
  AuthSession? _session;
  bool _isRestoring = false;
  bool _isSwitchingWarehouse = false;
  Failure? _restoreFailure;
  Failure? _switchWarehouseFailure;
  String? _sessionMessage;
  AuthSessionSource? _sessionSource;
  DateTime? _sessionFetchedAt;
  DateTime? _sessionExpiresAt;
  int _contextGeneration = 0;
  bool _isOwnershipTransitioning = false;
  Failure? _ownershipFailure;
  OfflineOwnershipReport? _lastOwnershipReport;
  bool _credentialsInvalidated = false;

  AuthSession? get session => _session;
  AppUser? get currentUser => _session?.user;
  Warehouse? get currentWarehouse => _session?.currentWarehouse;
  List<Warehouse> get warehouses => _session?.warehouses ?? const [];
  String? get accessToken => _session?.accessToken;
  bool get isAuthenticated => _session != null;
  bool get isRestoring => _isRestoring;
  bool get isSwitchingWarehouse => _isSwitchingWarehouse;
  Failure? get restoreFailure => _restoreFailure;
  Failure? get switchWarehouseFailure => _switchWarehouseFailure;
  String? get sessionMessage => _sessionMessage;
  AuthSessionSource? get sessionSource => _sessionSource;
  DateTime? get sessionFetchedAt => _sessionFetchedAt;
  DateTime? get sessionExpiresAt => _sessionExpiresAt;
  int get contextGeneration => _contextGeneration;
  bool get isOwnershipTransitioning => _isOwnershipTransitioning;
  Failure? get ownershipFailure => _ownershipFailure;
  OfflineOwnershipReport? get lastOwnershipReport => _lastOwnershipReport;
  bool get canAuthenticateRequests => !_credentialsInvalidated;
  bool get canAccessOfflineData {
    final accountId = currentUser?.id.toString();
    return !_isOwnershipTransitioning &&
        accountId != null &&
        (ownershipCoordinator?.canAccessOfflineData(accountId) ?? true);
  }

  bool get canSync {
    final accountId = currentUser?.id.toString();
    return !_isOwnershipTransitioning &&
        accountId != null &&
        (ownershipCoordinator?.canSync(accountId) ?? true);
  }

  Future<void> restoreSession(AuthRepository authRepository) async {
    await _restoreSession(
      authRepository,
      preserveActiveSessionOnFailure: false,
    );
  }

  Future<void> refreshSession(AuthRepository authRepository) async {
    await _restoreSession(authRepository, preserveActiveSessionOnFailure: true);
  }

  Future<void> _restoreSession(
    AuthRepository authRepository, {
    required bool preserveActiveSessionOnFailure,
  }) async {
    if (_isRestoring) {
      return;
    }

    final activeSession = _session;
    _isRestoring = true;
    _restoreFailure = null;
    notifyListeners();

    try {
      final result = await authRepository.restoreSession();

      switch (result) {
        case Success<AuthSession?>(data: final session):
          final candidate = _sessionWithActiveWarehouse(
            restoredSession: session,
            activeSession: activeSession,
            preserveActiveWarehouse: preserveActiveSessionOnFailure,
          );
          final ownershipReady = await _prepareOwnershipChange(
            activeSession,
            candidate,
          );
          if (ownershipReady) {
            _session = candidate;
            _credentialsInvalidated = candidate == null;
            _restoreFailure = null;
            _sessionMessage = null;
            final AuthSessionRestoreMetadata? metadata =
                authRepository is AuthSessionRestoreMetadata
                ? authRepository as AuthSessionRestoreMetadata
                : null;
            _sessionSource = session == null
                ? null
                : metadata?.lastRestoreSource ?? AuthSessionSource.network;
            _sessionFetchedAt = session == null
                ? null
                : metadata?.lastRestoreFetchedAt;
            _sessionExpiresAt = session == null
                ? null
                : metadata?.lastRestoreExpiresAt;
          } else {
            _session = activeSession;
            _restoreFailure = _ownershipFailure;
            _sessionMessage = _ownershipFailure?.message;
          }
        case FailureResult<AuthSession?>(failure: final failure):
          if (!preserveActiveSessionOnFailure ||
              activeSession == null ||
              failure is AuthenticationFailure ||
              failure is AuthorizationFailure ||
              failure is RevocationCleanupFailure) {
            _session = null;
          } else {
            _session = activeSession;
          }
          _restoreFailure = failure;
          _sessionMessage = failure.message;
          if (failure is AuthenticationFailure ||
              failure is AuthorizationFailure ||
              failure is RevocationCleanupFailure) {
            _credentialsInvalidated = true;
          }
          if (_session == null) _clearSourceMetadata();
      }
    } on Object catch (error) {
      _session = null;
      _credentialsInvalidated = true;
      _restoreFailure = LocalStorageFailure(
        message: '会话恢复失败，请重试',
        cause: error,
      );
      _sessionMessage = _restoreFailure!.message;
      _clearSourceMetadata();
    } finally {
      _isRestoring = false;
      _publishOwnershipChanges(activeSession, _session);
      notifyListeners();
    }
  }

  Future<bool> startSession(AuthSession session) async {
    final previous = _session;
    if (!await _prepareOwnershipChange(previous, session)) return false;
    _session = session;
    _credentialsInvalidated = false;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = null;
    _sessionSource = AuthSessionSource.network;
    _sessionFetchedAt = null;
    _sessionExpiresAt = null;
    _publishOwnershipChanges(previous, _session);
    notifyListeners();
    return true;
  }

  Future<bool> switchWarehouse({
    required AuthRepository authRepository,
    required Warehouse warehouse,
  }) async {
    final activeSession = _session;
    if (activeSession == null || _isSwitchingWarehouse) {
      return false;
    }

    if (activeSession.currentWarehouse?.id == warehouse.id) {
      _switchWarehouseFailure = null;
      notifyListeners();
      return true;
    }

    _isSwitchingWarehouse = true;
    _switchWarehouseFailure = null;
    notifyListeners();

    final result = await authRepository.switchCurrentWarehouse(warehouse);

    final bool success;
    switch (result) {
      case Success<Warehouse>(data: final confirmedWarehouse):
        final updatedWarehouses = activeSession.warehouses
            .map(
              (candidate) => candidate.id == confirmedWarehouse.id
                  ? confirmedWarehouse
                  : candidate,
            )
            .toList(growable: false);
        final updatedSession = AuthSession(
          accessToken: activeSession.accessToken,
          user: activeSession.user,
          currentWarehouse: confirmedWarehouse,
          warehouses: updatedWarehouses,
        );
        if (!await _prepareOwnershipChange(activeSession, updatedSession)) {
          _switchWarehouseFailure = _ownershipFailure;
          success = false;
          break;
        }
        _session = updatedSession;
        _publishOwnershipChanges(activeSession, _session);
        _switchWarehouseFailure = null;
        success = true;
      case FailureResult<Warehouse>(failure: final failure):
        _switchWarehouseFailure = failure;
        success = false;
    }

    _isSwitchingWarehouse = false;
    notifyListeners();
    return success;
  }

  Future<OfflineOwnershipReport?> expireSession({
    AuthRepository? authRepository,
    String message = '登录已过期，请重新登录',
  }) async {
    final previous = _session;
    final accountId = previous?.user.id.toString();
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = message;
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, _session);
    notifyListeners();

    OfflineOwnershipReport? report;
    try {
      if (accountId != null) {
        report = await _runOwnership(
          OfflineOwnershipIntent.tokenExpiry(accountId: accountId),
        );
      }
      final repository = authRepository;
      try {
        if (repository case final AuthCredentialInvalidator invalidator) {
          await invalidator.expireCredentials();
        } else {
          await repository?.logout();
        }
      } on Object catch (error) {
        _restoreFailure = LocalStorageFailure(
          message: '登录凭据清理失败，请重试',
          cause: error,
        );
        _sessionMessage = '$message；${_restoreFailure!.message}';
      }
      return report;
    } finally {
      notifyListeners();
    }
  }

  Future<OfflineOwnershipReport?> logout({
    required AuthRepository authRepository,
    DraftRetentionChoice draftRetention = DraftRetentionChoice.delete,
  }) async {
    if (_session == null &&
        _restoreFailure == null &&
        _sessionMessage == null) {
      await authRepository.logout();
      return null;
    }

    final previous = _session;
    final accountId = previous?.user.id.toString();
    final report = accountId == null
        ? null
        : await _runOwnership(
            OfflineOwnershipIntent.logout(
              accountId: accountId,
              draftRetention: draftRetention,
            ),
          );
    if (report != null && !report.completed) return report;
    await authRepository.logout();
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = null;
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, _session);
    notifyListeners();
    return report;
  }

  void invalidateRevokedSession() {
    final previous = _session;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthorizationFailure();
    _sessionMessage = '当前凭据已被撤销';
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();
  }

  Future<bool> _prepareOwnershipChange(
    AuthSession? previous,
    AuthSession? current,
  ) async {
    if (current == null) return true;
    final currentAccountId = current.user.id.toString();
    if (previous == null) {
      final report = await _runOwnership(
        OfflineOwnershipIntent.reauthenticated(accountId: currentAccountId),
      );
      return report?.completed ?? true;
    }

    final previousAccountId = previous.user.id.toString();
    if (previousAccountId != currentAccountId) {
      final report = await _runOwnership(
        OfflineOwnershipIntent.accountSwitch(
          previousAccountId: previousAccountId,
          currentAccountId: currentAccountId,
        ),
      );
      return report?.completed ?? true;
    }

    if (_authorizationFingerprint(previous) !=
        _authorizationFingerprint(current)) {
      final report = await _runOwnership(
        OfflineOwnershipIntent.permissionRefresh(accountId: currentAccountId),
      );
      if (report != null && !report.completed) return false;
    }
    final previousWarehouseId = previous.currentWarehouse?.id;
    final currentWarehouseId = current.currentWarehouse?.id;
    if (previousWarehouseId != null &&
        currentWarehouseId != null &&
        previousWarehouseId != currentWarehouseId) {
      final report = await _runOwnership(
        OfflineOwnershipIntent.warehouseSwitch(
          accountId: currentAccountId,
          previousWarehouseId: previousWarehouseId,
          currentWarehouseId: currentWarehouseId,
        ),
      );
      if (report != null && !report.completed) return false;
    }
    return true;
  }

  Future<OfflineOwnershipReport?> _runOwnership(
    OfflineOwnershipIntent intent,
  ) async {
    final coordinator = ownershipCoordinator;
    if (coordinator == null) {
      _ownershipFailure = null;
      return null;
    }
    _isOwnershipTransitioning = true;
    _ownershipFailure = null;
    notifyListeners();
    try {
      final report = await coordinator.apply(intent);
      _lastOwnershipReport = report;
      if (!report.completed) {
        _ownershipFailure = LocalStorageFailure(
          message: report.failures.map((failure) => failure.message).join(' '),
          cause: report,
        );
      }
      return report;
    } on Object catch (error) {
      _ownershipFailure = LocalStorageFailure(
        message: '离线数据归属处理失败',
        cause: error,
      );
      final report = OfflineOwnershipReport(
        reason: intent.reason,
        accountId: intent.accountId,
        executedCounts: const OfflineOwnershipCounts(),
        failures: [
          OfflineOwnershipFailure(
            step: OfflineOwnershipStep.store,
            message: _ownershipFailure!.message,
            cause: error,
          ),
        ],
      );
      _lastOwnershipReport = report;
      return report;
    } finally {
      _isOwnershipTransitioning = false;
      notifyListeners();
    }
  }

  String _authorizationFingerprint(AuthSession session) {
    final permissions = session.user.permissionCodes.toList()..sort();
    return '${session.user.roleCode}:${permissions.join(',')}';
  }

  void _clearSourceMetadata() {
    _sessionSource = null;
    _sessionFetchedAt = null;
    _sessionExpiresAt = null;
  }

  void _publishOwnershipChanges(AuthSession? previous, AuthSession? current) {
    if (_contextFingerprint(previous) != _contextFingerprint(current)) {
      _contextGeneration += 1;
    }
    final previousAccountId = previous?.user.id.toString();
    final currentAccountId = current?.user.id.toString();
    if (previousAccountId != currentAccountId) {
      eventBus?.publish(
        AccountOwnershipChangedEvent(
          previousAccountId: previousAccountId,
          currentAccountId: currentAccountId,
        ),
      );
    }
    if (currentAccountId != null &&
        previousAccountId == currentAccountId &&
        previous?.currentWarehouse?.id != current?.currentWarehouse?.id) {
      eventBus?.publish(
        WarehouseOwnershipChangedEvent(
          accountId: currentAccountId,
          previousWarehouseId: previous?.currentWarehouse?.id,
          currentWarehouseId: current?.currentWarehouse?.id,
        ),
      );
    }
  }

  String? _contextFingerprint(AuthSession? session) {
    if (session == null) return null;
    final permissions = session.user.permissionCodes.toList()..sort();
    return '${session.user.id}:${session.currentWarehouse?.id}:'
        '${session.user.roleCode}:${permissions.join(',')}';
  }

  AuthSession? _sessionWithActiveWarehouse({
    required AuthSession? restoredSession,
    required AuthSession? activeSession,
    required bool preserveActiveWarehouse,
  }) {
    final activeWarehouse = activeSession?.currentWarehouse;
    if (!preserveActiveWarehouse ||
        restoredSession == null ||
        activeWarehouse == null) {
      return restoredSession;
    }

    final restoredActiveWarehouse = _warehouseById(
      restoredSession.warehouses,
      activeWarehouse.id,
    );
    if (restoredActiveWarehouse == null) {
      return restoredSession;
    }

    return AuthSession(
      accessToken: restoredSession.accessToken,
      user: restoredSession.user,
      currentWarehouse: restoredActiveWarehouse,
      warehouses: restoredSession.warehouses,
    );
  }

  Warehouse? _warehouseById(List<Warehouse> warehouses, int warehouseId) {
    for (final warehouse in warehouses) {
      if (warehouse.id == warehouseId) {
        return warehouse;
      }
    }

    return null;
  }
}
