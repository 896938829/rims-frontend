abstract final class ApiEndpoints {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080/api/v1',
  );

  static const String login = '/auth/login';
  static const String currentUser = '/users/me';
  static const String currentUserWarehouses = '/users/me/warehouses';
  static const String inventory = '/inventory';
  static const String inventoryAlerts = '/inventory/alerts';
  static const String documents = '/documents';
  static const String salesStats = '/reports/sales/stats';
  static const String salesTrend = '/reports/sales/trend';
  static const String salesRanking = '/reports/sales/ranking';
  static const String inventoryOverview = '/reports/inventory/overview';
}
