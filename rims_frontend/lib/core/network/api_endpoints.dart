abstract final class ApiEndpoints {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  static const String login = '/auth/login';
  static const String currentUser = '/users/me';
  static const String currentUserPassword = '/users/me/password';
  static const String users = '/users';
  static String user(int id) => '$users/$id';
  static String userPassword(int id) => '$users/$id/password';
  static const String roles = '/roles';
  static String role(int id) => '$roles/$id';
  static String rolePermissions(int id) => '${role(id)}/permissions';
  static const String permissions = '/permissions';
  static const String products = '/products';
  static String product(int id) => '$products/$id';
  static const String warehouses = '/warehouses';
  static String warehouse(int id) => '$warehouses/$id';
  static String warehouseUsers(int id) => '$warehouses/$id/users';
  static String warehouseUser({required int warehouseId, required int userId}) {
    return '${warehouseUsers(warehouseId)}/$userId';
  }

  static const String currentUserWarehouses = '/users/me/warehouses';
  static const String currentUserCurrentWarehouse =
      '/users/me/warehouses/current';
  static const String inventory = '/inventory';
  static const String inventoryAlerts = '/inventory/alerts';
  static String inventoryItem(int id) => '$inventory/$id';

  static const String nonStandardInventory = '/non-std-inventory';
  static String productByBarcode(String barcode) {
    return '$products/barcode/${Uri.encodeComponent(barcode)}';
  }

  static const String documents = '/documents';
  static const String transactions = '/transactions';
  static const String salesStats = '/reports/sales/stats';
  static const String salesTrend = '/reports/sales/trend';
  static const String salesRanking = '/reports/sales/ranking';
  static const String inventoryOverview = '/reports/inventory/overview';
  static const String inventoryTurnover = '/reports/inventory/turnover';
  static const String inventorySlowMoving = '/reports/inventory/slow-moving';
}
