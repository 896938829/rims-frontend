import 'package:flutter/foundation.dart';

import '../../../../core/events/app_event.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/entities/admin_warehouse.dart';
import '../../domain/repositories/admin_repository.dart';

final class AdminWarehousesViewModel extends ChangeNotifier {
  AdminWarehousesViewModel({this.repository, this.eventBus});

  final AdminRepository? repository;
  final AppEventBus? eventBus;

  List<AdminWarehouse> _warehouses = const [];
  final Map<int, List<AdminUser>> _warehouseUsers = {};
  String _query = '';
  bool _isLoading = false;
  bool _isCreatingWarehouse = false;
  bool _isUpdatingWarehouse = false;
  bool _isDeletingWarehouse = false;
  bool _isLoadingWarehouseUsers = false;
  bool _isBindingWarehouseUsers = false;
  bool _isUnbindingWarehouseUser = false;
  bool _isDisposed = false;
  String? _errorMessage;
  String? _formError;
  String? _warehouseActionError;
  String? _userBindingError;
  int _page = 0;
  int _total = 0;
  int _generation = 0;
  bool _isLoadingMore = false;
  bool _reachedEnd = false;
  Failure? _loadMoreFailure;

  List<AdminWarehouse> get warehouses => _warehouses;
  String get query => _query;
  bool get isLoading => _isLoading;
  bool get isCreatingWarehouse => _isCreatingWarehouse;
  bool get isUpdatingWarehouse => _isUpdatingWarehouse;
  bool get isDeletingWarehouse => _isDeletingWarehouse;
  bool get isLoadingWarehouseUsers => _isLoadingWarehouseUsers;
  bool get isBindingWarehouseUsers => _isBindingWarehouseUsers;
  bool get isUnbindingWarehouseUser => _isUnbindingWarehouseUser;
  bool get isEmpty =>
      _warehouses.isEmpty && !_isLoading && _errorMessage == null;
  String? get errorMessage => _errorMessage;
  String? get formError => _formError;
  String? get warehouseActionError => _warehouseActionError;
  String? get userBindingError => _userBindingError;
  int get total => _total;
  bool get hasMore => _page > 0 && !_reachedEnd && _warehouses.length < _total;
  bool get isLoadingMore => _isLoadingMore;
  Failure? get loadMoreFailure => _loadMoreFailure;

  List<AdminUser> usersForWarehouse(int warehouseId) {
    return _warehouseUsers[warehouseId] ?? const [];
  }

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
      _warehouses = const [];
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

    final result = await repository.listWarehouses(
      keyword: _query.trim(),
      page: page,
    );

    if (generation != _generation) return;
    result.when(
      success: (pageData) {
        _warehouses = _merge(const [], pageData.items);
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
    final result = await repository.listWarehouses(
      keyword: keyword,
      page: _page + 1,
    );
    if (generation != _generation || keyword != _query.trim()) return;
    result.when(
      success: (pageData) {
        _warehouses = _merge(_warehouses, pageData.items);
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

  List<AdminWarehouse> _merge(
    List<AdminWarehouse> existing,
    List<AdminWarehouse> incoming,
  ) {
    final merged = List<AdminWarehouse>.of(existing);
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

  Future<bool> createWarehouse(CreateAdminWarehouseRequest request) async {
    if (_isCreatingWarehouse) {
      return false;
    }

    final normalizedRequest = CreateAdminWarehouseRequest(
      code: request.code.trim(),
      name: request.name.trim(),
      status: request.status,
      address: request.address.trim(),
      contactPerson: request.contactPerson.trim(),
      contactPhone: request.contactPhone.trim(),
    );

    if (!_isValidWarehouseIdentity(
      code: normalizedRequest.code,
      name: normalizedRequest.name,
    )) {
      _formError = '请填写仓库编码和名称';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isCreatingWarehouse = true;
    final hadLoadedPage = _page > 0;
    _formError = null;
    notifyListeners();

    var created = false;
    final result = await repository.createWarehouse(normalizedRequest);
    result.when(
      success: (warehouse) {
        _warehouses = [
          warehouse,
          ..._warehouses.where((candidate) => candidate.id != warehouse.id),
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

    _isCreatingWarehouse = false;
    notifyListeners();
    return created;
  }

  Future<bool> updateWarehouse(UpdateAdminWarehouseRequest request) async {
    if (_isUpdatingWarehouse) {
      return false;
    }

    final normalizedRequest = UpdateAdminWarehouseRequest(
      id: request.id,
      code: request.code.trim(),
      name: request.name.trim(),
      status: request.status,
      address: request.address.trim(),
      contactPerson: request.contactPerson.trim(),
      contactPhone: request.contactPhone.trim(),
    );

    if (!_isValidWarehouseIdentity(
      code: normalizedRequest.code,
      name: normalizedRequest.name,
    )) {
      _formError = '请填写仓库编码和名称';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _formError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isUpdatingWarehouse = true;
    final hadLoadedPage = _page > 0;
    _formError = null;
    notifyListeners();

    var updated = false;
    final result = await repository.updateWarehouse(normalizedRequest);
    result.when(
      success: (warehouse) {
        _warehouses = _warehouses
            .map(
              (candidate) =>
                  candidate.id == warehouse.id ? warehouse : candidate,
            )
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

    _isUpdatingWarehouse = false;
    notifyListeners();
    return updated;
  }

  Future<bool> deleteWarehouse(AdminWarehouse warehouse) async {
    if (_isDeletingWarehouse) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _warehouseActionError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isDeletingWarehouse = true;
    final hadLoadedPage = _page > 0;
    _warehouseActionError = null;
    notifyListeners();

    var deleted = false;
    final result = await repository.deleteWarehouse(warehouse.id);
    result.when(
      success: (_) {
        _warehouses = _warehouses
            .where((candidate) => candidate.id != warehouse.id)
            .toList(growable: false);
        _warehouseUsers.remove(warehouse.id);
        _warehouseActionError = null;
        deleted = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _warehouseActionError = failure.message;
      },
    );
    if (deleted && hadLoadedPage) await load();

    _isDeletingWarehouse = false;
    notifyListeners();
    return deleted;
  }

  Future<void> loadWarehouseUsers(AdminWarehouse warehouse) async {
    final repository = this.repository;
    if (repository == null) {
      _userBindingError = '管理服务不可用';
      notifyListeners();
      return;
    }

    _isLoadingWarehouseUsers = true;
    _userBindingError = null;
    notifyListeners();

    final users = <AdminUser>[];
    var pageNumber = 1;
    var completed = true;
    while (pageNumber > 0) {
      final result = await repository.listWarehouseUsers(
        warehouse.id,
        page: pageNumber,
      );
      switch (result) {
        case Success(:final data):
          users.addAll(data.items);
          pageNumber = data.items.isEmpty || !data.hasNextPage
              ? 0
              : data.nextPage;
        case FailureResult(:final failure):
          _userBindingError = failure.message;
          completed = false;
          pageNumber = 0;
      }
    }
    if (completed) {
      final byId = <int, AdminUser>{};
      for (final user in users) {
        byId[user.id] = user;
      }
      _warehouseUsers[warehouse.id] = List.unmodifiable(byId.values);
      _userBindingError = null;
    }

    _isLoadingWarehouseUsers = false;
    notifyListeners();
  }

  Future<bool> bindWarehouseUsers({
    required AdminWarehouse warehouse,
    required List<int> userIds,
  }) async {
    if (_isBindingWarehouseUsers) {
      return false;
    }

    final normalizedUserIds = userIds
        .where((userId) => userId > 0)
        .toSet()
        .toList(growable: false);

    if (normalizedUserIds.isEmpty) {
      _userBindingError = '请填写要绑定的用户 ID';
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _userBindingError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isBindingWarehouseUsers = true;
    _userBindingError = null;
    notifyListeners();

    var bound = false;
    final result = await repository.bindWarehouseUsers(
      BindWarehouseUsersRequest(
        warehouseId: warehouse.id,
        userIds: normalizedUserIds,
      ),
    );
    await result.when(
      success: (_) async {
        bound = true;
        await loadWarehouseUsers(warehouse);
        _publishGlobalRefresh();
      },
      failure: (failure) async {
        _userBindingError = failure.message;
      },
    );

    _isBindingWarehouseUsers = false;
    notifyListeners();
    return bound;
  }

  Future<bool> unbindWarehouseUser({
    required AdminWarehouse warehouse,
    required AdminUser user,
  }) async {
    if (_isUnbindingWarehouseUser) {
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _userBindingError = '管理服务不可用';
      notifyListeners();
      return false;
    }

    _isUnbindingWarehouseUser = true;
    _userBindingError = null;
    notifyListeners();

    var unbound = false;
    final result = await repository.unbindWarehouseUser(
      warehouseId: warehouse.id,
      userId: user.id,
    );
    result.when(
      success: (_) {
        _warehouseUsers[warehouse.id] = usersForWarehouse(
          warehouse.id,
        ).where((candidate) => candidate.id != user.id).toList(growable: false);
        _userBindingError = null;
        unbound = true;
        _publishGlobalRefresh();
      },
      failure: (failure) {
        _userBindingError = failure.message;
      },
    );

    _isUnbindingWarehouseUser = false;
    notifyListeners();
    return unbound;
  }

  bool _isValidWarehouseIdentity({required String code, required String name}) {
    return code.isNotEmpty && name.isNotEmpty;
  }

  void _publishGlobalRefresh() {
    eventBus?.publish(const GlobalRefreshRequestedEvent());
  }
}
