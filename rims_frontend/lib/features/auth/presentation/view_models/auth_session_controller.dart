import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/network/sanitized_transport_cause.dart';
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
  int _authEpoch = 0;
  bool _disposed = false;

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
  int get authEpoch => _authEpoch;

  int beginAuthenticationAttempt() => ++_authEpoch;
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
    if (_isRestoring || _disposed) {
      return;
    }

    var epoch = ++_authEpoch;
    final activeSession = _session;
    _isRestoring = true;
    _restoreFailure = null;
    notifyListeners();

    try {
      final result = await authRepository.restoreSession();
      final carriesSecurityFailure = switch (result) {
        FailureResult<AuthSession?>(
          failure: AuthenticationFailure() ||
              AuthorizationFailure() ||
              RevocationCleanupFailure(),
        ) =>
          true,
        _ => false,
      };
      if (!_isCurrent(epoch) &&
          _authEpoch == epoch + 1 &&
          _session == null &&
          _credentialsInvalidated &&
          carriesSecurityFailure) {
        // The repository synchronously invalidated this exact restore while it
        // continued its durable cleanup. Keep observing its typed outcome.
        epoch = _authEpoch;
      }
      if (!_isCurrent(epoch)) return;
      if (result is Success<AuthSession?> && _credentialsInvalidated) {
        return;
      }

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
          if (!_isCurrent(epoch)) return;
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
      if (!_isCurrent(epoch)) return;
      _session = null;
      _credentialsInvalidated = true;
      _restoreFailure = LocalStorageFailure(
        message: '会话恢复失败，请重试',
        cause: sanitizeTransportCause(error),
      );
      _sessionMessage = _restoreFailure!.message;
      _clearSourceMetadata();
    } finally {
      _isRestoring = false;
      if (_isCurrent(epoch)) {
        _publishOwnershipChanges(activeSession, _session);
        notifyListeners();
      }
    }
  }

  Future<bool> startSession(
    AuthSession session, {
    int? expectedEpoch,
    AuthSessionTransaction? transaction,
  }) async {
    if (_disposed || (expectedEpoch != null && expectedEpoch != _authEpoch)) {
      final rejectionEpoch = _authEpoch;
      final abortFailure = await _abortTransaction(
        transaction,
        reportFailure: false,
      );
      if (!_disposed &&
          rejectionEpoch == _authEpoch &&
          abortFailure != null &&
          _ownershipFailure == null &&
          _restoreFailure == null &&
          _switchWarehouseFailure == null) {
        _ownershipFailure = abortFailure;
        _sessionMessage = abortFailure.message;
        notifyListeners();
      }
      return false;
    }
    final epoch = expectedEpoch ?? ++_authEpoch;
    final previous = _session;
    final OwnershipPreparedAuthSessionTransaction? ownershipTransaction =
        transaction is OwnershipPreparedAuthSessionTransaction
        ? transaction as OwnershipPreparedAuthSessionTransaction
        : null;
    final preparedOwnership =
        ownershipTransaction?.hasPreparedReauthentication ?? false;
    final ownershipReady = await _prepareOwnershipChange(
      previous,
      session,
      skipReauthentication: preparedOwnership,
    );
    if (!_isCurrent(epoch)) {
      await _abortTransaction(transaction, reportFailure: false);
      return false;
    }
    if (!ownershipReady) {
      await _abortTransaction(transaction, expectedEpoch: epoch);
      return false;
    }
    if (!_isCurrent(epoch)) {
      await _abortTransaction(transaction, reportFailure: false);
      return false;
    }
    if (transaction != null) {
      final Result<void> commitResult;
      try {
        commitResult = await transaction.commit();
      } on Object catch (error) {
        if (!_isCurrent(epoch)) {
          await _abortTransaction(transaction, reportFailure: false);
          return false;
        }
        return _failSessionTransaction(
          epoch: epoch,
          previous: previous,
          transaction: transaction,
          failure: LocalStorageFailure(
            message: 'credential commit failed',
            cause: sanitizeTransportCause(error),
          ),
        );
      }
      if (!_isCurrent(epoch)) {
        await _abortTransaction(transaction, reportFailure: false);
        return false;
      }
      if (commitResult case FailureResult<void>(failure: final failure)) {
        return _failSessionTransaction(
          epoch: epoch,
          previous: previous,
          transaction: transaction,
          failure: failure,
        );
      }
      if (transaction
          case final OwnershipPreparedAuthSessionTransaction owned) {
        final Result<void> finalized;
        try {
          finalized = await owned.finalizeReauthentication();
        } on Object catch (error) {
          if (!_isCurrent(epoch)) {
            await _abortTransaction(transaction, reportFailure: false);
            return false;
          }
          return _failSessionTransaction(
            epoch: epoch,
            previous: previous,
            transaction: transaction,
            failure: LocalStorageFailure(
              message: 'ownership finalize failed',
              cause: sanitizeTransportCause(error),
            ),
          );
        }
        if (!_isCurrent(epoch)) {
          await _abortTransaction(transaction, reportFailure: false);
          return false;
        }
        if (finalized case FailureResult<void>(failure: final failure)) {
          return _failSessionTransaction(
            epoch: epoch,
            previous: previous,
            transaction: transaction,
            failure: failure,
          );
        }
      }
    }
    if (!_isCurrent(epoch)) return false;
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

  Future<bool> _failSessionTransaction({
    required int epoch,
    required AuthSession? previous,
    required AuthSessionTransaction transaction,
    required Failure failure,
  }) async {
    final abortFailure = await _abortTransaction(
      transaction,
      expectedEpoch: epoch,
      reportFailure: false,
    );
    if (!_isCurrent(epoch)) return false;
    final visibleFailure = abortFailure ?? failure;
    _session = previous;
    _credentialsInvalidated = previous == null;
    _ownershipFailure = visibleFailure;
    _sessionMessage = visibleFailure.message;
    notifyListeners();
    return false;
  }

  Future<Failure?> _abortTransaction(
    AuthSessionTransaction? transaction, {
    int? expectedEpoch,
    bool reportFailure = true,
  }) async {
    if (transaction == null) return null;
    Failure? abortFailure;
    try {
      final result = await transaction.abort();
      if (result case FailureResult<void>(failure: final failure)) {
        abortFailure = failure;
      }
    } on Object catch (error) {
      abortFailure = LocalStorageFailure(
        message: '登录事务清理失败，请重试',
        cause: sanitizeTransportCause(error),
      );
    }
    if (!reportFailure || _disposed) return abortFailure;
    if (expectedEpoch != null && !_isCurrent(expectedEpoch)) {
      return abortFailure;
    }
    if (abortFailure != null) {
      _ownershipFailure = abortFailure;
      _sessionMessage = abortFailure.message;
    }
    return abortFailure;
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
    final epoch = _authEpoch;
    _switchWarehouseFailure = null;
    notifyListeners();

    try {
      final result = await authRepository.switchCurrentWarehouse(warehouse);
      if (!_isCurrent(epoch)) return false;

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
          if (!await _prepareOwnershipChange(activeSession, updatedSession) ||
              !_isCurrent(epoch)) {
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
      return success;
    } on Object catch (error) {
      if (_isCurrent(epoch)) {
        _switchWarehouseFailure = LocalStorageFailure(
          message: '切换仓库失败，请重试',
          cause: sanitizeTransportCause(error),
        );
      }
      return false;
    } finally {
      _isSwitchingWarehouse = false;
      if (_isCurrent(epoch)) {
        notifyListeners();
      }
    }
  }

  Future<OfflineOwnershipReport?> expireSession({
    AuthRepository? authRepository,
    String message = '登录已过期，请重新登录',
  }) async {
    ++_authEpoch;
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
          cause: sanitizeTransportCause(error),
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
    final operationEpoch = _authEpoch;
    final previous = _session;
    _credentialsInvalidated = true;
    notifyListeners();
    if (_session == null &&
        _restoreFailure == null &&
        _sessionMessage == null) {
      await authRepository.logout();
      return null;
    }

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
    if (!_isCurrent(operationEpoch)) return report;
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
    ++_authEpoch;
    final previous = _session;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthorizationFailure();
    _sessionMessage = '当前凭据已被撤销';
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();
  }

  void invalidateExpiredSession() {
    ++_authEpoch;
    final previous = _session;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthenticationFailure();
    _sessionMessage = '登录已过期，请重新登录';
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();
  }

  Future<bool> _prepareOwnershipChange(
    AuthSession? previous,
    AuthSession? current, {
    bool skipReauthentication = false,
  }) async {
    if (current == null) return true;
    final currentAccountId = current.user.id.toString();
    if (previous == null) {
      if (skipReauthentication) return true;
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
        cause: sanitizeTransportCause(error),
      );
      final report = OfflineOwnershipReport(
        reason: intent.reason,
        accountId: intent.accountId,
        executedCounts: const OfflineOwnershipCounts(),
        failures: [
          OfflineOwnershipFailure(
            step: OfflineOwnershipStep.store,
            message: _ownershipFailure!.message,
            cause: sanitizeTransportCause(error),
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

  bool _isCurrent(int epoch) => !_disposed && epoch == _authEpoch;

  @override
  void dispose() {
    _disposed = true;
    ++_authEpoch;
    super.dispose();
  }
}
