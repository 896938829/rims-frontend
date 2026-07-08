import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/admin_product.dart';
import '../../domain/entities/admin_role.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/entities/admin_warehouse.dart';
import '../models/admin_product_models.dart';
import '../models/admin_role_models.dart';
import '../models/admin_user_models.dart';
import '../models/admin_warehouse_models.dart';

const int _adminListPageSize = 20;

abstract interface class AdminRemoteDataSource {
  Future<Result<List<AdminUserModel>>> listUsers({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminUserModel>> createUser(CreateAdminUserRequest request);

  Future<Result<AdminUserModel>> updateUser(UpdateAdminUserRequest request);

  Future<Result<void>> deleteUser(int id);

  Future<Result<List<AdminProductModel>>> listProducts({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminProductModel>> createProduct(
    CreateAdminProductRequest request,
  );

  Future<Result<AdminProductModel>> updateProduct(
    UpdateAdminProductRequest request,
  );

  Future<Result<void>> deleteProduct(int id);

  Future<Result<List<AdminWarehouseModel>>> listWarehouses({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminWarehouseModel>> createWarehouse(
    CreateAdminWarehouseRequest request,
  );

  Future<Result<AdminWarehouseModel>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  );

  Future<Result<void>> deleteWarehouse(int id);

  Future<Result<List<AdminUserModel>>> listWarehouseUsers(int warehouseId);

  Future<Result<void>> bindWarehouseUsers(BindWarehouseUsersRequest request);

  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  });

  Future<Result<List<AdminRoleModel>>> listRoles();

  Future<Result<List<AdminPermissionModel>>> listPermissions();

  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  );

  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request);

  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request);
}

final class ApiAdminRemoteDataSource implements AdminRemoteDataSource {
  const ApiAdminRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<List<AdminUserModel>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    final trimmedKeyword = keyword.trim();
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.users,
      queryParameters: {
        if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
        'page': page,
        'pageSize': _adminListPageSize,
      },
    );

    return _mapEnvelope(result, _parseUsers);
  }

  @override
  Future<Result<AdminUserModel>> createUser(
    CreateAdminUserRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.users,
      data: createAdminUserRequestToJson(request),
    );

    return _mapEnvelope(result, _parseUser);
  }

  @override
  Future<Result<AdminUserModel>> updateUser(
    UpdateAdminUserRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.user(request.id),
      data: updateAdminUserRequestToJson(request),
    );

    return _mapEnvelope(result, _parseUser);
  }

  @override
  Future<Result<void>> deleteUser(int id) async {
    final result = await _apiClient.delete<dynamic>(ApiEndpoints.user(id));

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<List<AdminProductModel>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    final trimmedKeyword = keyword.trim();
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.products,
      queryParameters: {
        if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
        'page': page,
        'pageSize': _adminListPageSize,
      },
    );

    return _mapEnvelope(result, _parseProducts);
  }

  @override
  Future<Result<AdminProductModel>> createProduct(
    CreateAdminProductRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.products,
      data: createAdminProductRequestToJson(request),
    );

    return _mapEnvelope(result, _parseProduct);
  }

  @override
  Future<Result<AdminProductModel>> updateProduct(
    UpdateAdminProductRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.product(request.id),
      data: updateAdminProductRequestToJson(request),
    );

    return _mapEnvelope(result, _parseProduct);
  }

  @override
  Future<Result<void>> deleteProduct(int id) async {
    final result = await _apiClient.delete<dynamic>(ApiEndpoints.product(id));

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<List<AdminWarehouseModel>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    final trimmedKeyword = keyword.trim();
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.warehouses,
      queryParameters: {
        if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
        'page': page,
        'pageSize': _adminListPageSize,
      },
    );

    return _mapEnvelope(result, _parseWarehouses);
  }

  @override
  Future<Result<AdminWarehouseModel>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.warehouses,
      data: createAdminWarehouseRequestToJson(request),
    );

    return _mapEnvelope(result, _parseWarehouse);
  }

  @override
  Future<Result<AdminWarehouseModel>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.warehouse(request.id),
      data: updateAdminWarehouseRequestToJson(request),
    );

    return _mapEnvelope(result, _parseWarehouse);
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) async {
    final result = await _apiClient.delete<dynamic>(ApiEndpoints.warehouse(id));

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<List<AdminUserModel>>> listWarehouseUsers(
    int warehouseId,
  ) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.warehouseUsers(warehouseId),
    );

    return _mapEnvelope(result, _parseUsers);
  }

  @override
  Future<Result<void>> bindWarehouseUsers(
    BindWarehouseUsersRequest request,
  ) async {
    final result = await _apiClient.post<dynamic>(
      ApiEndpoints.warehouseUsers(request.warehouseId),
      data: bindWarehouseUsersRequestToJson(request),
    );

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) async {
    final result = await _apiClient.delete<dynamic>(
      ApiEndpoints.warehouseUser(warehouseId: warehouseId, userId: userId),
    );

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<List<AdminRoleModel>>> listRoles() async {
    final result = await _apiClient.get<dynamic>(ApiEndpoints.roles);

    return _mapEnvelope(result, _parseRoles);
  }

  @override
  Future<Result<List<AdminPermissionModel>>> listPermissions() async {
    final result = await _apiClient.get<dynamic>(ApiEndpoints.permissions);

    return _mapEnvelope(result, _parsePermissions);
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.rolePermissions(request.roleId),
      data: updateRolePermissionsRequestToJson(request),
    );

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<void>> changeOwnPassword(
    ChangeOwnPasswordRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.currentUserPassword,
      data: changeOwnPasswordRequestToJson(request),
    );

    return _mapEnvelope(result, (_) {});
  }

  @override
  Future<Result<void>> resetUserPassword(
    ResetUserPasswordRequest request,
  ) async {
    final result = await _apiClient.put<dynamic>(
      ApiEndpoints.userPassword(request.userId),
      data: resetUserPasswordRequestToJson(request),
    );

    return _mapEnvelope(result, (_) {});
  }

  Result<T> _mapEnvelope<T>(
    Result<Response<dynamic>> responseResult,
    T Function(Object? data) convert,
  ) {
    return responseResult.when(
      success: (response) {
        final responseData = response.data;
        if (responseData is! Map<dynamic, dynamic>) {
          return FailureResult<T>(
            UnknownFailure(
              message: 'Invalid API response',
              statusCode: response.statusCode,
            ),
          );
        }

        final envelope = ApiEnvelope.fromJson(responseData);
        if (!envelope.isSuccess) {
          return FailureResult<T>(
            UnknownFailure(
              message: envelope.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
            ),
          );
        }

        try {
          return Success<T>(convert(envelope.data));
        } on FormatException catch (error) {
          return FailureResult<T>(
            UnknownFailure(
              message: error.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
              cause: error,
            ),
          );
        }
      },
      failure: FailureResult<T>.new,
    );
  }

  AdminUserModel _parseUser(Object? data) {
    return _parseUserMap(_requiredMap(data, 'user'));
  }

  AdminProductModel _parseProduct(Object? data) {
    return _parseProductMap(_requiredMap(data, 'product'));
  }

  AdminWarehouseModel _parseWarehouse(Object? data) {
    return _parseWarehouseMap(_requiredMap(data, 'warehouse'));
  }

  List<AdminUserModel> _parseUsers(Object? data) {
    final rawList = _requiredList(data, 'users');

    return _requiredMapItems(
      rawList,
      'users',
    ).map(_parseUserMap).toList(growable: false);
  }

  List<AdminProductModel> _parseProducts(Object? data) {
    final rawList = _requiredList(data, 'products');

    return _requiredMapItems(
      rawList,
      'products',
    ).map(_parseProductMap).toList(growable: false);
  }

  List<AdminWarehouseModel> _parseWarehouses(Object? data) {
    final rawList = _requiredList(data, 'warehouses');

    return _requiredMapItems(
      rawList,
      'warehouses',
    ).map(_parseWarehouseMap).toList(growable: false);
  }

  List<AdminRoleModel> _parseRoles(Object? data) {
    final rawList = _requiredList(data, 'roles');

    return _requiredMapItems(
      rawList,
      'roles',
    ).map(_parseRoleMap).toList(growable: false);
  }

  List<AdminPermissionModel> _parsePermissions(Object? data) {
    final rawList = _requiredList(data, 'permissions');

    return _requiredMapItems(
      rawList,
      'permissions',
    ).map(_parsePermissionMap).toList(growable: false);
  }

  Map<dynamic, dynamic> _requiredMap(Object? data, String name) {
    if (data is Map) {
      return data;
    }

    throw FormatException('Invalid $name response');
  }

  AdminUserModel _parseUserMap(Map<dynamic, dynamic> json) {
    final user = AdminUserModel.fromJson(json);
    if (user.id <= 0 || user.username.isEmpty) {
      throw const FormatException('Invalid user response');
    }

    return user;
  }

  AdminProductModel _parseProductMap(Map<dynamic, dynamic> json) {
    final product = AdminProductModel.fromJson(json);
    if (product.id <= 0 ||
        product.code.isEmpty ||
        product.name.isEmpty ||
        product.unit.isEmpty) {
      throw const FormatException('Invalid product response');
    }

    return product;
  }

  AdminWarehouseModel _parseWarehouseMap(Map<dynamic, dynamic> json) {
    final warehouse = AdminWarehouseModel.fromJson(json);
    if (warehouse.id <= 0 || warehouse.code.isEmpty || warehouse.name.isEmpty) {
      throw const FormatException('Invalid warehouse response');
    }

    return warehouse;
  }

  AdminRoleModel _parseRoleMap(Map<dynamic, dynamic> json) {
    final role = AdminRoleModel.fromJson(json);
    if (role.id <= 0 || role.code.isEmpty || role.name.isEmpty) {
      throw const FormatException('Invalid role response');
    }

    return role;
  }

  AdminPermissionModel _parsePermissionMap(Map<dynamic, dynamic> json) {
    final permission = AdminPermissionModel.fromJson(json);
    if (permission.id <= 0 ||
        permission.code.isEmpty ||
        permission.name.isEmpty) {
      throw const FormatException('Invalid permission response');
    }

    return permission;
  }

  List<dynamic> _requiredList(Object? data, String name) {
    return switch (data) {
      {'list': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      {'rows': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => throw FormatException('Invalid $name response'),
    };
  }

  List<Map<dynamic, dynamic>> _requiredMapItems(
    List<dynamic> list,
    String name,
  ) {
    return list
        .map((item) {
          if (item is Map) {
            return Map<dynamic, dynamic>.from(item);
          }

          throw FormatException('Invalid $name response');
        })
        .toList(growable: false);
  }
}
