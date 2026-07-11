import '../../../../core/result/result.dart';
import '../../../../core/pagination/page_data.dart';
import '../entities/admin_product.dart';
import '../entities/admin_role.dart';
import '../entities/admin_user.dart';
import '../entities/admin_warehouse.dart';

abstract interface class AdminRepository {
  Future<Result<PageData<AdminUser>>> listUsers({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminUser>> createUser(CreateAdminUserRequest request);

  Future<Result<AdminUser>> updateUser(UpdateAdminUserRequest request);

  Future<Result<void>> deleteUser(int id);

  Future<Result<PageData<AdminProduct>>> listProducts({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminProduct>> createProduct(CreateAdminProductRequest request);

  Future<Result<AdminProduct>> updateProduct(UpdateAdminProductRequest request);

  Future<Result<void>> deleteProduct(int id);

  Future<Result<PageData<AdminWarehouse>>> listWarehouses({
    String keyword = '',
    int page = 1,
  });

  Future<Result<AdminWarehouse>> createWarehouse(
    CreateAdminWarehouseRequest request,
  );

  Future<Result<AdminWarehouse>> updateWarehouse(
    UpdateAdminWarehouseRequest request,
  );

  Future<Result<void>> deleteWarehouse(int id);

  Future<Result<List<AdminUser>>> listWarehouseUsers(int warehouseId);

  Future<Result<void>> bindWarehouseUsers(BindWarehouseUsersRequest request);

  Future<Result<void>> unbindWarehouseUser({
    required int warehouseId,
    required int userId,
  });

  Future<Result<List<AdminRole>>> listRoles();

  Future<Result<List<AdminPermission>>> listPermissions();

  Future<Result<void>> updateRolePermissions(
    UpdateRolePermissionsRequest request,
  );

  Future<Result<void>> changeOwnPassword(ChangeOwnPasswordRequest request);

  Future<Result<void>> resetUserPassword(ResetUserPasswordRequest request);
}
