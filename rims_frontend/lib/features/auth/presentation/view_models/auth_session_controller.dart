import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/network/sanitized_transport_cause.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/terminal_session_revocation.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/services/authenticated_request_lease.dart';
import '../../domain/services/auth_session_lifecycle_gate.dart';
import '../../domain/services/session_refresh_coordinator.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';

final class AuthLoginAttempt {
  AuthLoginAttempt._(this._owner);

  AuthSessionController? _owner;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool _isActiveFor(AuthSessionController owner) =>
      identical(_owner, owner) && !_cancelled;

  void _complete(AuthSessionController owner) {
    if (identical(_owner, owner)) _owner = null;
  }
}

final class AuthSessionController extends ChangeNotifier {
  AuthSessionController({
    this.eventBus,
    this.ownershipCoordinator,
    AuthSessionLifecycleGate? lifecycleGate,
  }) : lifecycleGate = lifecycleGate ?? AuthSessionLifecycleGate();

  final AppEventBus? eventBus;
  final OfflineOwnershipCoordinator? ownershipCoordinator;
  final AuthSessionLifecycleGate lifecycleGate;
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

  AuthLoginAttempt createLoginAttempt() {
    final attempt = AuthLoginAttempt._(this);
    if (_disposed) attempt.cancel();
    return attempt;
  }

  Future<Result<void>> login({
    required AuthRepository authRepository,
    required String username,
    required String password,
    AuthLoginAttempt? attempt,
  }) => lifecycleGate.run(() async {
    final loginAttempt = attempt ?? createLoginAttempt();
    if (!loginAttempt._isActiveFor(this)) {
      return const FailureResult<void>(
        StateFailure(message: 'Login attempt was cancelled.'),
      );
    }
    final epoch = ++_authEpoch;
    try {
      if (authRepository case final TransactionalAuthRepository transactional) {
        final prepared = await transactional.prepareLogin(
          username: username,
          password: password,
        );
        return switch (prepared) {
          Success<AuthSessionTransaction>(data: final transaction) =>
            await _startSession(
                  transaction.session,
                  expectedEpoch: epoch,
                  transaction: transaction,
                  loginAttempt: loginAttempt,
                )
                ? const Success<void>(null)
                : FailureResult<void>(
                    _ownershipFailure ??
                        const StateFailure(message: 'Unable to start session.'),
                  ),
          FailureResult<AuthSessionTransaction>(failure: final failure) =>
            FailureResult<void>(failure),
        };
      }
      final result = await authRepository.login(
        username: username,
        password: password,
      );
      if (result case FailureResult<AuthSession>(failure: final failure)) {
        return FailureResult<void>(failure);
      }
      final session = (result as Success<AuthSession>).data;
      final accepted = await _startSession(
        session,
        expectedEpoch: epoch,
        loginAttempt: loginAttempt,
      );
      if (accepted) return const Success<void>(null);
      final cleanupFailure = await _quarantineFallbackLogin(
        authRepository,
        session,
      );
      return FailureResult<void>(
        cleanupFailure ??
            _ownershipFailure ??
            const StateFailure(message: 'Unable to start session.'),
      );
    } on Object catch (error) {
      return FailureResult<void>(
        UnknownFailure(
          message: 'Unable to sign in.',
          cause: sanitizeTransportCause(error),
        ),
      );
    } finally {
      loginAttempt._complete(this);
    }
  });
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

  Future<void> restoreSession(AuthRepository authRepository) =>
      lifecycleGate.run(
        () => _restoreSession(
          authRepository,
          preserveActiveSessionOnFailure: false,
        ),
      );

  Future<void> refreshSession(AuthRepository authRepository) =>
      lifecycleGate.run(
        () => _restoreSession(
          authRepository,
          preserveActiveSessionOnFailure: true,
        ),
      );

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
  }) => lifecycleGate.run(
    () => _startSession(
      session,
      expectedEpoch: expectedEpoch,
      transaction: transaction,
    ),
  );

  Future<bool> _startSession(
    AuthSession session, {
    int? expectedEpoch,
    AuthSessionTransaction? transaction,
    AuthLoginAttempt? loginAttempt,
  }) async {
    if (_disposed ||
        (expectedEpoch != null && expectedEpoch != _authEpoch) ||
        !_isLoginAttemptActive(loginAttempt)) {
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
    if (!_isCurrentLogin(epoch, loginAttempt)) {
      await _abortTransaction(transaction, reportFailure: false);
      return false;
    }
    if (!ownershipReady) {
      await _abortTransaction(transaction, expectedEpoch: epoch);
      return false;
    }
    if (!_isCurrentLogin(epoch, loginAttempt)) {
      await _abortTransaction(transaction, reportFailure: false);
      return false;
    }
    if (transaction != null) {
      final Result<void> commitResult;
      try {
        commitResult = await transaction.commit();
      } on Object catch (error) {
        if (!_isCurrentLogin(epoch, loginAttempt)) {
          await _abortTransaction(transaction, reportFailure: false);
          return false;
        }
        return _failSessionTransaction(
          epoch: epoch,
          previous: previous,
          transaction: transaction,
          loginAttempt: loginAttempt,
          failure: LocalStorageFailure(
            message: 'credential commit failed',
            cause: sanitizeTransportCause(error),
          ),
        );
      }
      if (!_isCurrentLogin(epoch, loginAttempt)) {
        await _abortTransaction(transaction, reportFailure: false);
        return false;
      }
      if (commitResult case FailureResult<void>(failure: final failure)) {
        return _failSessionTransaction(
          epoch: epoch,
          previous: previous,
          transaction: transaction,
          loginAttempt: loginAttempt,
          failure: failure,
        );
      }
      if (transaction
          case final OwnershipPreparedAuthSessionTransaction owned) {
        final Result<void> finalized;
        try {
          finalized = await owned.finalizeReauthentication();
        } on Object catch (error) {
          if (!_isCurrentLogin(epoch, loginAttempt)) {
            await _abortTransaction(transaction, reportFailure: false);
            return false;
          }
          return _failSessionTransaction(
            epoch: epoch,
            previous: previous,
            transaction: transaction,
            loginAttempt: loginAttempt,
            failure: LocalStorageFailure(
              message: 'ownership finalize failed',
              cause: sanitizeTransportCause(error),
            ),
          );
        }
        if (!_isCurrentLogin(epoch, loginAttempt)) {
          await _abortTransaction(transaction, reportFailure: false);
          return false;
        }
        if (finalized case FailureResult<void>(failure: final failure)) {
          return _failSessionTransaction(
            epoch: epoch,
            previous: previous,
            transaction: transaction,
            loginAttempt: loginAttempt,
            failure: failure,
          );
        }
      }
    }
    if (!_isCurrentLogin(epoch, loginAttempt)) return false;
    _session = session;
    _credentialsInvalidated = false;
    _ownershipFailure = null;
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
    AuthLoginAttempt? loginAttempt,
  }) async {
    final abortFailure = await _abortTransaction(
      transaction,
      expectedEpoch: epoch,
      reportFailure: false,
    );
    if (!_isCurrentLogin(epoch, loginAttempt)) return false;
    final visibleFailure = abortFailure ?? failure;
    _session = previous;
    _credentialsInvalidated = previous == null;
    _ownershipFailure = visibleFailure;
    _sessionMessage = visibleFailure.message;
    notifyListeners();
    return false;
  }

  Future<Failure?> _quarantineFallbackLogin(
    AuthRepository authRepository,
    AuthSession rejectedSession,
  ) async {
    final quarantine = switch (authRepository) {
      final OwnerBoundCredentialQuarantine value => value,
      _ => null,
    };
    if (quarantine == null) {
      return const LocalStorageFailure(
        message: 'Unable to quarantine the abandoned credential.',
      );
    }
    try {
      final credential = await quarantine.captureCredentialForQuarantine();
      if (credential == null ||
          credential.accessToken != rejectedSession.accessToken) {
        return null;
      }
      if (await quarantine.quarantineCredential(credential)) return null;
      return const LocalStorageFailure(
        message: 'Unable to quarantine the abandoned credential.',
      );
    } on Object catch (error) {
      return LocalStorageFailure(
        message: 'Unable to quarantine the abandoned credential.',
        cause: sanitizeTransportCause(error),
      );
    }
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
  }) => lifecycleGate.run(
    () =>
        _switchWarehouse(authRepository: authRepository, warehouse: warehouse),
  );

  Future<bool> _switchWarehouse({
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
  }) => lifecycleGate.run(
    () => _expireSession(authRepository: authRepository, message: message),
  );

  Future<OfflineOwnershipReport?> _expireSession({
    required AuthRepository? authRepository,
    required String message,
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
  }) => lifecycleGate.run(
    () =>
        _logout(authRepository: authRepository, draftRetention: draftRetention),
  );

  Future<OfflineOwnershipReport?> _logout({
    required AuthRepository authRepository,
    required DraftRetentionChoice draftRetention,
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

  Future<int> invalidateRevokedSession() => lifecycleGate.run(() async {
    ++_authEpoch;
    final previous = _session;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthorizationFailure();
    _sessionMessage = '当前凭据已被撤销';
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();
    return _authEpoch;
  });

  Future<TerminalSessionRevocationResult> runSessionRevocation({
    required AuthRepository authRepository,
    required Future<Result<void>> Function() remoteRevocation,
    String message = '当前登录设备已撤销，请重新登录',
  }) => lifecycleGate.run(
    () => _runSessionRevocation(
      authRepository: authRepository,
      remoteRevocation: remoteRevocation,
      message: message,
    ),
  );

  Future<TerminalSessionRevocationResult> _runSessionRevocation({
    required AuthRepository authRepository,
    required Future<Result<void>> Function() remoteRevocation,
    required String message,
  }) async {
    final quarantine = switch (authRepository) {
      final OwnerBoundCredentialQuarantine value => value,
      _ => null,
    };
    if (quarantine == null) {
      return const TerminalSessionRevocationResult.remoteRejected(
        StateFailure(message: '无法建立本机凭据安全清理事务'),
      );
    }
    final DeviceCredential? expectedCredential;
    try {
      expectedCredential = await quarantine.captureCredentialForQuarantine();
    } on Object catch (error) {
      return TerminalSessionRevocationResult.remoteRejected(
        LocalStorageFailure(
          message: '读取本机登录凭据失败，请重试',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
    if (expectedCredential == null) {
      return const TerminalSessionRevocationResult.remoteRejected(
        AuthenticationFailure(message: '当前登录凭据不可用'),
      );
    }

    final remoteResult = await remoteRevocation();
    if (remoteResult case FailureResult<void>(failure: final failure)) {
      return TerminalSessionRevocationResult.remoteRejected(failure);
    }

    final requestEpoch = _authEpoch;
    final previous = _session;
    final accountId = expectedCredential.accountId;
    final cleanupEpoch = ++_authEpoch;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthorizationFailure();
    _switchWarehouseFailure = null;
    _sessionMessage = message;
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();

    final requestLease = AuthenticatedRequestLease(
      token: expectedCredential.accessToken,
      credential: expectedCredential,
      authEpoch: requestEpoch,
    );
    final cleanupLease = AuthenticatedSessionCleanupLease(
      request: requestLease,
      cleanupEpoch: cleanupEpoch,
    );
    final markerLease = SessionRevocationLease(
      accountId: expectedCredential.accountId,
      sessionId: expectedCredential.sessionId,
      generation: expectedCredential.generation,
      authEpoch: requestEpoch,
    );
    final recovery = switch (authRepository) {
      final SessionFailureRecovery value => value,
      _ => null,
    };
    Failure? retentionFailure;
    if (recovery != null) {
      try {
        retentionFailure = await recovery.retainPendingRevocation(
          markerLease: markerLease,
          cleanupLease: cleanupLease,
        );
      } on Object catch (error) {
        retentionFailure = RevocationCleanupFailure(
          message: '本机安全清理记录保存失败',
          cause: sanitizeTransportCause(error),
        );
      }
    }

    var ownershipCompleted = true;
    Failure? directCleanupFailure;
    try {
      final report = await _runOwnership(
        OfflineOwnershipIntent.revocation(accountId: accountId),
      );
      ownershipCompleted = report?.completed ?? true;
      if (!ownershipCompleted) {
        directCleanupFailure =
            _ownershipFailure ??
            const RevocationCleanupFailure(message: '离线数据安全清理失败');
      }
    } on Object catch (error) {
      ownershipCompleted = false;
      directCleanupFailure = RevocationCleanupFailure(
        message: '离线数据安全清理失败',
        cause: sanitizeTransportCause(error),
      );
    }

    var credentialQuarantined = false;
    try {
      credentialQuarantined = await quarantine.quarantineCredential(
        expectedCredential,
      );
      if (!credentialQuarantined) {
        directCleanupFailure ??= const RevocationCleanupFailure(
          message: '本机登录凭据尚未完成隔离',
        );
      }
    } on Object catch (error) {
      directCleanupFailure ??= RevocationCleanupFailure(
        message: '本机登录凭据隔离失败',
        cause: sanitizeTransportCause(error),
      );
    }

    Failure? completionFailure;
    if (recovery != null) {
      try {
        completionFailure = await recovery.completeOwnershipCleanup(
          markerLease: markerLease,
          cleanupLease: cleanupLease,
          credentialQuarantined: credentialQuarantined,
          ownershipCompleted: ownershipCompleted,
        );
      } on Object catch (error) {
        completionFailure = RevocationCleanupFailure(
          message: '本机安全清理未完成',
          cause: sanitizeTransportCause(error),
        );
      }
    }

    final cleanupFailure = recovery == null
        ? directCleanupFailure
        : completionFailure == null
        ? null
        : RevocationCleanupFailure(
            message: completionFailure.message,
            cause: [
              if (retentionFailure != null)
                sanitizeTransportCause(retentionFailure),
              sanitizeTransportCause(completionFailure),
            ],
          );
    if (cleanupFailure != null) {
      _restoreFailure = cleanupFailure;
      _sessionMessage = '当前登录已撤销；本机安全清理将在下次登录前继续';
      notifyListeners();
      return TerminalSessionRevocationResult.cleanupDebt(cleanupFailure);
    }
    _ownershipFailure = null;
    return const TerminalSessionRevocationResult.completed();
  }

  Future<int> invalidateExpiredSession() => lifecycleGate.run(() async {
    ++_authEpoch;
    final previous = _session;
    _session = null;
    _credentialsInvalidated = true;
    _restoreFailure = const AuthenticationFailure();
    _sessionMessage = '登录已过期，请重新登录';
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, null);
    notifyListeners();
    return _authEpoch;
  });

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

  bool _isLoginAttemptActive(AuthLoginAttempt? attempt) =>
      attempt == null || attempt._isActiveFor(this);

  bool _isCurrentLogin(int epoch, AuthLoginAttempt? attempt) =>
      _isCurrent(epoch) && _isLoginAttemptActive(attempt);

  @override
  void dispose() {
    _disposed = true;
    ++_authEpoch;
    super.dispose();
  }
}
