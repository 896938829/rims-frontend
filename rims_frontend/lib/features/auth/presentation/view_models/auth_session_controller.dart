import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';

final class AuthSessionController extends ChangeNotifier {
  AuthSessionController({this.eventBus});

  final AppEventBus? eventBus;
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

    final result = await authRepository.restoreSession();

    result.when(
      success: (session) {
        _session = _sessionWithActiveWarehouse(
          restoredSession: session,
          activeSession: activeSession,
          preserveActiveWarehouse: preserveActiveSessionOnFailure,
        );
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
      },
      failure: (failure) {
        if (!preserveActiveSessionOnFailure ||
            activeSession == null ||
            failure is AuthenticationFailure) {
          _session = null;
        } else {
          _session = activeSession;
        }
        _restoreFailure = failure;
        _sessionMessage = failure.message;
        if (_session == null) _clearSourceMetadata();
      },
    );

    _isRestoring = false;
    _publishOwnershipChanges(activeSession, _session);
    notifyListeners();
  }

  void startSession(AuthSession session) {
    final previous = _session;
    _session = session;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = null;
    _sessionSource = AuthSessionSource.network;
    _sessionFetchedAt = null;
    _sessionExpiresAt = null;
    _publishOwnershipChanges(previous, _session);
    notifyListeners();
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

    final success = result.when(
      success: (confirmedWarehouse) {
        final updatedWarehouses = activeSession.warehouses
            .map(
              (candidate) => candidate.id == confirmedWarehouse.id
                  ? confirmedWarehouse
                  : candidate,
            )
            .toList(growable: false);
        _session = AuthSession(
          accessToken: activeSession.accessToken,
          user: activeSession.user,
          currentWarehouse: confirmedWarehouse,
          warehouses: updatedWarehouses,
        );
        _publishOwnershipChanges(activeSession, _session);
        _switchWarehouseFailure = null;
        return true;
      },
      failure: (failure) {
        _switchWarehouseFailure = failure;
        return false;
      },
    );

    _isSwitchingWarehouse = false;
    notifyListeners();
    return success;
  }

  void expireSession({String message = '登录已过期，请重新登录'}) {
    final previous = _session;
    _session = null;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = message;
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, _session);
    notifyListeners();
  }

  void logout() {
    if (_session == null &&
        _restoreFailure == null &&
        _sessionMessage == null) {
      return;
    }

    final previous = _session;
    _session = null;
    _restoreFailure = null;
    _switchWarehouseFailure = null;
    _sessionMessage = null;
    _clearSourceMetadata();
    _publishOwnershipChanges(previous, _session);
    notifyListeners();
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
