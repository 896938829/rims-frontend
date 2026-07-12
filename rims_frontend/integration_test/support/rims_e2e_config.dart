abstract final class RimsE2eConfig {
  static const String adminUsername = String.fromEnvironment(
    'RIMS_E2E_ADMIN_USERNAME',
    defaultValue: 'admin',
  );
  static const String adminPassword = String.fromEnvironment(
    'RIMS_E2E_ADMIN_PASSWORD',
    defaultValue: 'admin123',
  );
  static const String operatorUsername = String.fromEnvironment(
    'RIMS_E2E_OPERATOR_USERNAME',
    defaultValue: 'm9_operator',
  );
  static const String operatorPassword = String.fromEnvironment(
    'RIMS_E2E_OPERATOR_PASSWORD',
    defaultValue: 'admin123',
  );
  static const String fixtureProductCode = 'M9-PAGE-0001';
  static const String secondWarehouseName = 'M9 验收二号仓';
  static const bool fieldOperationsEnabled = bool.fromEnvironment(
    'RIMS_E2E_FIELD_OPERATIONS',
  );
  static const String injectedBarcode = String.fromEnvironment(
    'RIMS_E2E_BARCODE',
    defaultValue: fixtureProductCode,
  );
  static const String injectedPickedFile = String.fromEnvironment(
    'RIMS_E2E_PICKED_FILE',
    defaultValue: 'provider-file',
  );
}
