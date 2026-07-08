import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../domain/entities/admin_role.dart';
import '../../domain/repositories/admin_repository.dart';

final class AdminRolesViewModel extends ChangeNotifier {
  AdminRolesViewModel({this.repository, this.eventBus});

  final AdminRepository? repository;
  final AppEventBus? eventBus;

  List<AdminRole> _roles = const [];
  List<AdminPermission> _permissions = const [];
  bool _isLoading = false;
  bool _isSavingPermissions = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _permissionActionError;

  List<AdminRole> get roles => _roles;
  List<AdminPermission> get permissions => _permissions;
  bool get isLoading => _isLoading;
  bool get isSavingPermissions => _isSavingPermissions;
  bool get isEmpty => _roles.isEmpty && !_isLoading && _errorMessage == null;
  String? get errorMessage => _errorMessage;
  String? get permissionActionError => _permissionActionError;

  @override
  void notifyListeners() {
    if (_isDisposed) {
      return;
    }

    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  Future<void> load() async {
    final repository = this.repository;
    if (repository == null) {
      _roles = const [];
      _permissions = const [];
      _errorMessage = '管理服务不可用';
      notifyListeners();
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _permissionActionError = null;
    notifyListeners();

    final rolesResult = await repository.listRoles();
    var shouldLoadPermissions = false;
    rolesResult.when(
      success: (roles) {
        _roles = roles;
        _errorMessage = null;
        shouldLoadPermissions = true;
      },
      failure: (failure) {
        _errorMessage = failure.message;
      },
    );

    if (shouldLoadPermissions) {
      final permissionsResult = await repository.listPermissions();
      permissionsResult.when(
        success: (permissions) {
          _permissions = permissions;
          _errorMessage = null;
        },
        failure: (failure) {
          _errorMessage = failure.message;
        },
      );
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> saveRolePermissions({
    required AdminRole role,
    required List<int> permissionIds,
  }) async {
    if (_isSavingPermissions) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _permissionActionError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    final normalizedPermissionIds = _normalizePermissionIds(permissionIds);

    _isSavingPermissions = true;
    _permissionActionError = null;
    notifyListeners();

    var saved = false;
    final result = await repository.updateRolePermissions(
      UpdateRolePermissionsRequest(
        roleId: role.id,
        permissionIds: normalizedPermissionIds,
      ),
    );
    result.when(
      success: (_) {
        _roles = _roles
            .map(
              (candidate) => candidate.id == role.id
                  ? candidate.copyWith(permissionIds: normalizedPermissionIds)
                  : candidate,
            )
            .toList(growable: false);
        _permissionActionError = null;
        saved = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _permissionActionError = failure.message;
      },
    );

    _isSavingPermissions = false;
    notifyListeners();
    return saved;
  }

  void _publishGlobalRefresh() {
    eventBus?.publish(const GlobalRefreshRequestedEvent());
  }
}

List<int> _normalizePermissionIds(List<int> permissionIds) {
  final seen = <int>{};
  final normalized = <int>[];
  for (final permissionId in permissionIds) {
    if (permissionId > 0 && seen.add(permissionId)) {
      normalized.add(permissionId);
    }
  }

  return normalized;
}
