import '../../../../core/result/result.dart';
import '../../domain/entities/admin_product.dart';
import '../../domain/entities/admin_role.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/entities/admin_warehouse.dart';
import '../../domain/repositories/admin_repository.dart';
import '../datasources/admin_remote_datasource.dart';

final class AdminRepositoryImpl implements AdminRepository {
  const AdminRepositoryImpl({required this.remoteDataSource});

  final AdminRemoteDataSource remoteDataSource;

  @override
  Future<Result<List<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listUsers(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<AdminUser>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminUser>>.new,
    );
  }

  @override
  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request) async {
    final result = await remoteDataSource.createUser(request);

    return result.when(
      success: (model) => Success<AdminUser>(model.toEntity()),
      failure: FailureResult<AdminUser>.new,
    );
  }

  @override
  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request) async {
    final result = await remoteDataSource.updateUser(request);

    return result.when(
      success: (model) => Success<AdminUser>(model.toEntity()),
      failure: FailureResult<AdminUser>.new,
    );
  }

  @override
  Future<Result<void>> deleteUser(int id) {
    return remoteDataSource.deleteUser(id);
  }

  @override
  Future<Result<List<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listProducts(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<AdminProduct>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminProduct>>.new,
    );
  }

  @override
  Future<Result<AdminProduct>> createProduct(
    CreateAdminProductRequest request,
  ) async {
    final result = await remoteDataSource.createProduct(request);

    return result.when(
      success: (model) => Success<AdminProduct>(model.toEntity()),
      failure: FailureResult<AdminProduct>.new,
    );
  }

  @override
  Future<Result<AdminProduct>> updateProduct(
    UpdateAdminProductRequest request,
  ) async {
    final result = await remoteDataSource.updateProduct(request);

    return result.when(
      success: (model) => Success<AdminProduct>(model.toEntity()),
      failure: FailureResult<AdminProduct>.new,
    );
  }

  @override
  Future<Result<void>> deleteProduct(int id) {
    return remoteDataSource.deleteProduct(id);
  }

  @override
  Future<Result<List<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  }) async {
    final result = await remoteDataSource.listWarehouses(
      keyword: keyword,
      page: page,
    );

    return result.when(
      success: (models) => Success<List<AdminWarehouse>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminWarehouse>>.new,
    );
  }

  @override
  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  ) async {
    final result = await remoteDataSource.createWarehouse(request);

    return result.when(
      success: (model) => Success<AdminWarehouse>(model.toEntity()),
      failure: FailureResult<AdminWarehouse>.new,
    );
  }

  @override
  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  ) async {
    final result = await remoteDataSource.updateWarehouse(request);

    return result.when(
      success: (model) => Success<AdminWarehouse>(model.toEntity()),
      failure: FailureResult<AdminWarehouse>.new,
    );
  }

  @override
  Future<Result<void>> deleteWarehouse(int id) {
    return remoteDataSource.deleteWarehouse(id);
  }

  @override
  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId) async {
    final result = await remoteDataSource.listWarehouseUsers(warehouseId);

    return result.when(
      success: (models) => Success<List<AdminUser>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminUser>>.new,
    );
  }

  @override
  Future<Result<void>> bindWarehouseUsers(BindWarehouseUsersRequest request) {
    return remoteDataSource.bindWarehouseUsers(request);
  }

  @override
  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  }) {
    return remoteDataSource.unbindWarehouseUser(
      warehouseId: warehouseId,
      userId: userId,
    );
  }

  @override
  Future<Result<List<AdminRole>>> listRoles() async {
    final result = await remoteDataSource.listRoles();

    return result.when(
      success: (models) => Success<List<AdminRole>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminRole>>.new,
    );
  }

  @override
  Future<Result<List<AdminPermission>>> listPermissions() async {
    final result = await remoteDataSource.listPermissions();

    return result.when(
      success: (models) => Success<List<AdminPermission>>(
        models.map((model) => model.toEntity()).toList(growable: false),
      ),
      failure: FailureResult<List<AdminPermission>>.new,
    );
  }

  @override
  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  ) {
    return remoteDataSource.updateRolePermissions(request);
  }

  @override
  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request) {
    return remoteDataSource.changeOwnPassword(request);
  }

  @override
  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request) {
    return remoteDataSource.resetUserPassword(request);
  }
}
