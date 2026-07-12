import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';

final class ProfileViewModel {
  const ProfileViewModel({
    required this.user,
    required this.warehouse,
    this.warehouses = const [],
  });

  final AppUser user;
  final Warehouse? warehouse;
  final List<Warehouse> warehouses;

  String get userName =>
      user.realName.isNotEmpty ? user.realName : user.username;
  String get workId => 'ID ${user.id}';
  String get roleName => user.roleName;
  String get warehouseName => warehouse?.name ?? '未选择仓库';
  bool get canSwitchWarehouse => user.isAdmin && warehouses.length > 1;
  bool get showsAssignedWarehouses => !user.isAdmin && warehouses.length > 1;
  String get assignedWarehouseNames =>
      warehouses.map((warehouse) => warehouse.name).toSet().join('、');
}
