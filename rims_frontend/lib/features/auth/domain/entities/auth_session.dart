import 'app_user.dart';
import 'warehouse.dart';

final class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.user,
    required this.currentWarehouse,
    required this.warehouses,
  });

  final String accessToken;
  final AppUser user;
  final Warehouse? currentWarehouse;
  final List<Warehouse> warehouses;
}
