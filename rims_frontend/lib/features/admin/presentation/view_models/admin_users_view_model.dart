import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/repositories/admin_repository.dart';

final class AdminUsersViewModel extends ChangeNotifier {
  AdminUsersViewModel({this.repository, this.eventBus});

  final AdminRepository? repository;
  final AppEventBus? eventBus;

  List<AdminUser> _users = const [];
  String _query = '';
  bool _isLoading = false;
  bool _isCreatingUser = false;
  bool _isUpdatingUser = false;
  bool _isDeletingUser = false;
  bool _isResettingPassword = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _formError;
  String? _userActionError;
  String? _passwordActionError;
  int _page = 0;
  int _total = 0;
  int _generation = 0;
  bool _isLoadingMore = false;
  bool _reachedEnd = false;
  Failure? _loadMoreFailure;

  List<AdminUser> get users => _users;
  String get query => _query;
  bool get isLoading => _isLoading;
  bool get isCreatingUser => _isCreatingUser;
  bool get isUpdatingUser => _isUpdatingUser;
  bool get isDeletingUser => _isDeletingUser;
  bool get isResettingPassword => _isResettingPassword;
  bool get isEmpty => _users.isEmpty && !_isLoading && _errorMessage == null;
  String? get errorMessage => _errorMessage;
  String? get formError => _formError;
  String? get userActionError => _userActionError;
  String? get passwordActionError => _passwordActionError;
  int get total => _total;
  bool get hasMore => _page > 0 && !_reachedEnd && _users.length < _total;
  bool get isLoadingMore => _isLoadingMore;
  Failure? get loadMoreFailure => _loadMoreFailure;

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

  Future<void> load({int page = 1}) async {
    final generation = ++_generation;
    final repository = this.repository;
    if (repository == null) {
      _users = const [];
      _errorMessage = '管理服务不可用';
      notifyListeners();
      return;
    }

    _isLoading = true;
    _page = 0;
    _total = 0;
    _isLoadingMore = false;
    _reachedEnd = false;
    _loadMoreFailure = null;
    _errorMessage = null;
    notifyListeners();

    final result = await repository.listUsers(
      keyword: _query.trim(),
      page: page,
    );

    if (generation != _generation) return;
    result.when(
      success: (pageData) {
        _users = _merge(const [], pageData.items);
        _page = pageData.page;
        _total = pageData.total;
        _reachedEnd = pageData.items.isEmpty || !pageData.hasNextPage;
        _errorMessage = null;
      },
      failure: (failure) {
        _errorMessage = failure.message;
      },
    );

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    final repository = this.repository;
    if (repository == null || _isLoadingMore || !hasMore) return;
    final generation = _generation;
    final keyword = _query.trim();
    _isLoadingMore = true;
    _loadMoreFailure = null;
    notifyListeners();
    final result = await repository.listUsers(
      keyword: keyword,
      page: _page + 1,
    );
    if (generation != _generation || keyword != _query.trim()) return;
    result.when(
      success: (pageData) {
        _users = _merge(_users, pageData.items);
        _page = pageData.page;
        _total = pageData.total;
        _reachedEnd = pageData.items.isEmpty || !pageData.hasNextPage;
      },
      failure: (failure) => _loadMoreFailure = failure,
    );
    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> retryLoadMore() => loadMore();

  List<AdminUser> _merge(List<AdminUser> existing, List<AdminUser> incoming) {
    final merged = List<AdminUser>.of(existing);
    final indexes = <int, int>{
      for (var i = 0; i < merged.length; i++) merged[i].id: i,
    };
    for (final item in incoming) {
      final index = indexes[item.id];
      if (index == null) {
        indexes[item.id] = merged.length;
        merged.add(item);
      } else {
        merged[index] = item;
      }
    }
    return List.unmodifiable(merged);
  }

  Future<void> updateQuery(String value) async {
    if (_query == value) {
      return;
    }

    _query = value;
    await load();
  }

  Future<bool> createUser(CreateAdminUserRequest request) async {
    if (_isCreatingUser) {
      return false;
    }

    final normalizedRequest = CreateAdminUserRequest(
      username: request.username.trim(),
      password: request.password,
      realName: request.realName.trim(),
      phone: request.phone.trim(),
      email: request.email.trim(),
      roleId: request.roleId,
    );

    if (normalizedRequest.username.isEmpty ||
        normalizedRequest.password.isEmpty ||
        normalizedRequest.roleId <= 0) {
      _formError = '请填写用户名、密码和角色 ID';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isCreatingUser = true;
    final hadLoadedPage = _page > 0;
    _formError = null;
    notifyListeners();

    var created = false;
    final result = await repository.createUser(normalizedRequest);
    result.when(
      success: (user) {
        _users = [
          user,
          ..._users.where((candidate) => candidate.id != user.id),
        ];
        _formError = null;
        created = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );
    if (created && hadLoadedPage) await load();

    _isCreatingUser = false;
    notifyListeners();
    return created;
  }

  Future<bool> updateUser(UpdateAdminUserRequest request) async {
    if (_isUpdatingUser) {
      return false;
    }

    if ((request.roleId ?? 1) <= 0) {
      _formError = '请填写有效角色 ID';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isUpdatingUser = true;
    final hadLoadedPage = _page > 0;
    _formError = null;
    notifyListeners();

    var updated = false;
    final result = await repository.updateUser(request);
    result.when(
      success: (user) {
        _users = _users
            .map((candidate) => candidate.id == user.id ? user : candidate)
            .toList(growable: false);
        _formError = null;
        updated = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _formError = failure.message;
      },
    );
    if (updated && hadLoadedPage) await load();

    _isUpdatingUser = false;
    notifyListeners();
    return updated;
  }

  Future<bool> deleteUser(AdminUser user) async {
    if (_isDeletingUser) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _userActionError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isDeletingUser = true;
    final hadLoadedPage = _page > 0;
    _userActionError = null;
    notifyListeners();

    var deleted = false;
    final result = await repository.deleteUser(user.id);
    result.when(
      success: (_) {
        _users = _users
            .where((candidate) => candidate.id != user.id)
            .toList(growable: false);
        _userActionError = null;
        deleted = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _userActionError = failure.message;
      },
    );
    if (deleted && hadLoadedPage) await load();

    _isDeletingUser = false;
    notifyListeners();
    return deleted;
  }

  Future<bool> resetUserPassword({
    required int userId,
    required String newPassword,
  }) async {
    if (_isResettingPassword) {
      return false;
    }

    final password = newPassword.trim();
    if (password.isEmpty) {
      _passwordActionError = '请填写新密码';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _passwordActionError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isResettingPassword = true;
    _passwordActionError = null;
    notifyListeners();

    var reset = false;
    final result = await repository.resetUserPassword(
      ResetUserPasswordRequest(userId: userId, newPassword: password),
    );
    result.when(
      success: (_) {
        _passwordActionError = null;
        reset = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _passwordActionError = failure.message;
      },
    );

    _isResettingPassword = false;
    notifyListeners();
    return reset;
  }

  void _publishGlobalRefresh() {
    eventBus?.publish(const GlobalRefreshRequestedEvent());
  }
}
